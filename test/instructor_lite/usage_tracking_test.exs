defmodule InstructorLite.UsageTrackingTest do
  use ExUnit.Case, async: true

  import Mox

  alias InstructorLite

  setup :verify_on_exit!

  defmodule TestAdapter do
    @behaviour InstructorLite.Adapter

    def send_request(_params, _opts) do
      {:ok,
       %{
         "content" => [%{"input" => %{"name" => "John", "age" => 25}}],
         "stop_reason" => "tool_use",
         "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
       }}
    end

    def initial_prompt(params, _opts) do
      Map.put(params, :tools, [%{name: "Schema", input_schema: %{}}])
    end

    def retry_prompt(params, _resp_params, _errors, _response, _opts) do
      Map.put(params, :retry, true)
    end

    def parse_response(response, _opts) do
      case response do
        %{"content" => [%{"input" => decoded}]} ->
          {:ok, decoded}

        _ ->
          {:error, :unexpected_response, response}
      end
    end

    def extract_usage(response) do
      Map.get(response, "usage")
    end
  end

  describe "usage tracking" do
    test "returns usage metadata when include_usage is true" do
      {:ok, result, metadata} =
        InstructorLite.instruct(
          %{messages: [%{role: "user", content: "test"}]},
          response_model: %{name: :string, age: :integer},
          adapter: TestAdapter,
          include_usage: true
        )

      assert result == %{name: "John", age: 25}
      assert metadata.total == %{"input_tokens" => 100, "output_tokens" => 50}
      assert metadata.attempts == [%{"input_tokens" => 100, "output_tokens" => 50}]
    end

    test "does not return usage metadata when include_usage is false" do
      {:ok, result} =
        InstructorLite.instruct(
          %{messages: [%{role: "user", content: "test"}]},
          response_model: %{name: :string, age: :integer},
          adapter: TestAdapter,
          include_usage: false
        )

      assert result == %{name: "John", age: 25}
    end

    test "aggregates usage across retries" do
      defmodule RetryAdapter do
        @behaviour InstructorLite.Adapter

        def send_request(params, _opts) do
          # Return different usage for each attempt based on retry flag
          response =
            if Map.get(params, :retry) do
              %{
                "content" => [%{"input" => %{"name" => "John", "age" => 25}}],
                "stop_reason" => "tool_use",
                "usage" => %{"input_tokens" => 120, "output_tokens" => 45}
              }
            else
              %{
                "content" => [%{"input" => %{"name" => "J", "age" => 25}}],
                "stop_reason" => "tool_use",
                "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
              }
            end

          {:ok, response}
        end

        def initial_prompt(params, _opts) do
          Map.put(params, :tools, [%{name: "Schema", input_schema: %{}}])
        end

        def retry_prompt(params, _resp_params, _errors, _response, _opts) do
          Map.put(params, :retry, true)
        end

        def parse_response(response, _opts) do
          case response do
            %{"content" => [%{"input" => decoded}]} ->
              {:ok, decoded}

            _ ->
              {:error, :unexpected_response, response}
          end
        end

        def extract_usage(response) do
          Map.get(response, "usage")
        end
      end

      defmodule ValidatedSchema do
        use Ecto.Schema
        use InstructorLite.Instruction

        @primary_key false
        embedded_schema do
          field(:name, :string)
          field(:age, :integer)
        end

        @impl true
        def validate_changeset(changeset, _opts) do
          # Fail if name is too short (first attempt will have "J")
          name = Ecto.Changeset.get_field(changeset, :name)

          if name && String.length(name) < 2 do
            Ecto.Changeset.add_error(changeset, :name, "too short")
          else
            changeset
          end
        end
      end

      {:ok, result, metadata} =
        InstructorLite.instruct(
          %{messages: [%{role: "user", content: "test"}]},
          response_model: ValidatedSchema,
          adapter: RetryAdapter,
          include_usage: true,
          max_retries: 1
        )

      assert result.name == "John"
      assert result.age == 25

      # Check aggregated usage
      assert metadata.total == %{"input_tokens" => 220, "output_tokens" => 95}
      assert length(metadata.attempts) == 2

      assert metadata.attempts == [
               %{"input_tokens" => 100, "output_tokens" => 50},
               %{"input_tokens" => 120, "output_tokens" => 45}
             ]
    end

    test "returns usage in error cases" do
      defmodule FailingAdapter do
        @behaviour InstructorLite.Adapter

        def send_request(_params, _opts) do
          {:ok,
           %{
             # Missing age field
             "content" => [%{"input" => %{"name" => "J"}}],
             "stop_reason" => "tool_use",
             "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
           }}
        end

        def initial_prompt(params, _opts) do
          Map.put(params, :tools, [%{name: "Schema", input_schema: %{}}])
        end

        def retry_prompt(params, _resp_params, _errors, _response, _opts) do
          Map.put(params, :retry, true)
        end

        def parse_response(response, _opts) do
          case response do
            %{"content" => [%{"input" => decoded}]} ->
              {:ok, decoded}

            _ ->
              {:error, :unexpected_response, response}
          end
        end

        def extract_usage(response) do
          Map.get(response, "usage")
        end
      end

      defmodule StrictSchema do
        use Ecto.Schema
        use InstructorLite.Instruction

        @primary_key false
        embedded_schema do
          field(:name, :string)
          field(:age, :integer)
        end

        @impl true
        def validate_changeset(changeset, _opts) do
          changeset
          |> Ecto.Changeset.validate_required([:name, :age])
        end
      end

      {:error, changeset, metadata} =
        InstructorLite.instruct(
          %{messages: [%{role: "user", content: "test"}]},
          response_model: StrictSchema,
          adapter: FailingAdapter,
          include_usage: true,
          max_retries: 0
        )

      assert %Ecto.Changeset{} = changeset
      assert metadata.total == %{"input_tokens" => 100, "output_tokens" => 50}
      assert metadata.attempts == [%{"input_tokens" => 100, "output_tokens" => 50}]
    end

    test "handles adapters without extract_usage implementation" do
      defmodule NoUsageAdapter do
        @behaviour InstructorLite.Adapter

        def send_request(_params, _opts) do
          {:ok,
           %{
             "content" => [%{"input" => %{"name" => "John", "age" => 25}}],
             "stop_reason" => "tool_use"
           }}
        end

        def initial_prompt(params, _opts) do
          Map.put(params, :tools, [%{name: "Schema", input_schema: %{}}])
        end

        def retry_prompt(params, _resp_params, _errors, _response, _opts) do
          Map.put(params, :retry, true)
        end

        def parse_response(response, _opts) do
          case response do
            %{"content" => [%{"input" => decoded}]} ->
              {:ok, decoded}

            _ ->
              {:error, :unexpected_response, response}
          end
        end

        # No extract_usage implementation
      end

      {:ok, result, metadata} =
        InstructorLite.instruct(
          %{messages: [%{role: "user", content: "test"}]},
          response_model: %{name: :string, age: :integer},
          adapter: NoUsageAdapter,
          include_usage: true
        )

      assert result == %{name: "John", age: 25}
      assert metadata.total == %{}
      assert metadata.attempts == [%{}]
    end
  end
end
