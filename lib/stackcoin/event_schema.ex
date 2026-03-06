defmodule StackCoin.EventSchema do
  @moduledoc """
  Macro for defining event types with a single canonical definition that
  generates both Ecto embedded schemas (for internal validation) and
  OpenApiSpex schemas (for API spec generation).

  ## Usage

      defmodule StackCoin.Core.EventData do
        use StackCoin.EventSchema

        defevent "transfer.completed", TransferCompleted do
          field :transaction_id, :integer, required: true, description: "Transaction ID"
          field :from_id, :integer, required: true, description: "Sender user ID"
        end
      end

  Each `defevent` generates:
  - An Ecto embedded schema submodule with a `changeset/1`
  - An OpenApiSpex data schema under `StackCoinWeb.Schemas`
  - An OpenApiSpex event wrapper schema under `StackCoinWeb.Schemas`
  - Registry entries for runtime lookup

  At compile time, `__before_compile__` generates:
  - `StackCoinWeb.Schemas.Event` (discriminated union)
  - `StackCoinWeb.Schemas.EventsResponse` (list wrapper)
  - `schema_for/1` and `event_types/0` functions
  """

  defmacro __using__(_opts) do
    quote do
      import StackCoin.EventSchema, only: [defevent: 3]
      Module.register_attribute(__MODULE__, :events, accumulate: true)
      @before_compile StackCoin.EventSchema
    end
  end

  defmacro defevent(type_string, name_ast, do: block) do
    fields = parse_fields(block)

    # Resolve the alias to an atom at compile time
    name =
      case name_ast do
        {:__aliases__, _, parts} -> Module.concat(parts)
        atom when is_atom(atom) -> atom
      end

    # Use inspect to get "TransferCompleted" (not "Elixir.TransferCompleted" from Atom.to_string)
    name_str = inspect(name)

    all_field_names = Enum.map(fields, fn {fname, _ftype, _opts} -> fname end)
    required_fields = for {fname, _ftype, opts} <- fields, opts[:required], do: fname

    # Build Ecto field AST
    ecto_field_asts =
      Enum.map(fields, fn {fname, ftype, _opts} ->
        quote do: Ecto.Schema.field(unquote(fname), unquote(ftype))
      end)

    # Build OpenApiSpex properties map
    oapi_properties =
      Map.new(fields, fn {fname, ftype, opts} ->
        oapi_type = ecto_to_oapi_type(ftype)
        description = Keyword.get(opts, :description, to_string(fname))
        required = Keyword.get(opts, :required, true)

        schema_opts = %{type: oapi_type, description: description}

        schema_opts =
          if not required, do: Map.put(schema_opts, :nullable, true), else: schema_opts

        {fname, struct(OpenApiSpex.Schema, schema_opts)}
      end)

    data_schema_name = Module.concat(StackCoinWeb.Schemas, :"#{name_str}Data")
    event_schema_name = Module.concat(StackCoinWeb.Schemas, :"#{name_str}Event")

    quote do
      @events {unquote(type_string), unquote(name), unquote(Macro.escape(fields))}

      # Ecto embedded schema
      defmodule Module.concat(__MODULE__, unquote(name)) do
        use Ecto.Schema
        import Ecto.Changeset

        @primary_key false
        embedded_schema do
          (unquote_splicing(ecto_field_asts))
        end

        def changeset(params) do
          %__MODULE__{}
          |> cast(params, unquote(all_field_names))
          |> validate_required(unquote(required_fields))
        end
      end

      # OpenApiSpex data schema
      defmodule unquote(data_schema_name) do
        require OpenApiSpex

        OpenApiSpex.schema(%{
          title: unquote("#{name_str}Data"),
          description: unquote("Data payload for #{type_string} events"),
          type: :object,
          properties: unquote(Macro.escape(oapi_properties)),
          required: unquote(required_fields)
        })
      end

      # OpenApiSpex event wrapper schema
      defmodule unquote(event_schema_name) do
        require OpenApiSpex

        OpenApiSpex.schema(%{
          title: unquote("#{name_str}Event"),
          description: unquote("A #{type_string} event"),
          type: :object,
          properties: %{
            id: %OpenApiSpex.Schema{type: :integer, description: "Event ID"},
            type: %OpenApiSpex.Schema{
              type: :string,
              description: "Event type",
              enum: [unquote(type_string)]
            },
            data: unquote(data_schema_name),
            inserted_at: %OpenApiSpex.Schema{
              type: :string,
              description: "Event timestamp",
              format: :"date-time"
            }
          },
          required: [:id, :type, :data, :inserted_at]
        })
      end
    end
  end

  defmacro __before_compile__(env) do
    # Reverse to match definition order (@events accumulates in reverse)
    events = Module.get_attribute(env.module, :events) |> Enum.reverse()

    schema_for_clauses =
      for {type_string, name, _fields} <- events do
        ecto_module = Module.concat(env.module, name)

        quote do
          def schema_for(unquote(type_string)), do: {:ok, unquote(ecto_module)}
        end
      end

    event_types = Enum.map(events, fn {type_string, _name, _fields} -> type_string end)

    event_schema_modules =
      Enum.map(events, fn {_type_string, name, _fields} ->
        Module.concat(StackCoinWeb.Schemas, :"#{inspect(name)}Event")
      end)

    discriminator_mapping =
      for {type_string, name, _fields} <- events, into: %{} do
        {type_string, "#/components/schemas/#{inspect(name)}Event"}
      end

    event_module = Module.concat(StackCoinWeb.Schemas, :Event)
    events_response_module = Module.concat(StackCoinWeb.Schemas, :EventsResponse)

    quote do
      unquote_splicing(schema_for_clauses)
      def schema_for(_type), do: {:error, :unknown_event_type}

      def event_types, do: unquote(event_types)

      def validate(type, data) when is_binary(type) and is_map(data) do
        case schema_for(type) do
          {:ok, schema_mod} ->
            changeset = schema_mod.changeset(data)

            if changeset.valid? do
              {:ok, Ecto.Changeset.apply_changes(changeset)}
            else
              {:error, {:invalid_event_data, changeset.errors}}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end

      defmodule unquote(event_module) do
        require OpenApiSpex

        OpenApiSpex.schema(%{
          title: "Event",
          description: "A StackCoin event (discriminated by type)",
          oneOf: unquote(event_schema_modules),
          discriminator: %OpenApiSpex.Discriminator{
            propertyName: "type",
            mapping: unquote(Macro.escape(discriminator_mapping))
          }
        })
      end

      defmodule unquote(events_response_module) do
        require OpenApiSpex

        OpenApiSpex.schema(%{
          title: "EventsResponse",
          description: "Response schema for listing events",
          type: :object,
          properties: %{
            events: %OpenApiSpex.Schema{
              description: "The events list",
              type: :array,
              items: unquote(event_module)
            }
          },
          required: [:events]
        })
      end
    end
  end

  # --- Compile-time helpers ---

  @doc false
  def parse_fields({:__block__, _, statements}) do
    Enum.map(statements, &parse_field/1)
  end

  def parse_fields(statement) do
    [parse_field(statement)]
  end

  defp parse_field({:field, _, [name, type, opts]}) do
    {name, type, opts}
  end

  defp parse_field({:field, _, [name, type]}) do
    {name, type, []}
  end

  defp ecto_to_oapi_type(:integer), do: :integer
  defp ecto_to_oapi_type(:string), do: :string
  defp ecto_to_oapi_type(:boolean), do: :boolean
  defp ecto_to_oapi_type(:float), do: :number
  defp ecto_to_oapi_type(_), do: :string
end
