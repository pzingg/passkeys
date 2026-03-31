defmodule Passkeys do
  @moduledoc """
  Passkeys keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  def wax_origin do
    Application.get_env(:wax_, :origin)
  end

  def wax_rp_id do
    case Application.get_env(:wax_, :rp_id) do
      rp_id when is_binary(rp_id) ->
        rp_id

      :auto ->
        case wax_origin() do
          dest when is_binary(dest) ->
            dest |> URI.parse() |> Map.get(:host)

          _ ->
            "localhost"
        end

      _ ->
        "localhost"
    end
  end

  def with_wax_origin(url) when is_binary(url) do
    case wax_origin() do
      dest when is_binary(dest) ->
        src = URI.parse(url)
        dest = URI.parse(dest)
        %{dest | path: src.path, query: src.query, fragment: src.fragment} |> URI.to_string()

      _ ->
        url
    end
  end
end
