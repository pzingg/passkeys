defmodule PasskeysWeb.PageController do
  use PasskeysWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
