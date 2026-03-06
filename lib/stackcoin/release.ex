defmodule StackCoin.Release do
  @moduledoc """
  Release tasks that can be run without Mix.

  Used by `rel/overlays/bin/migrate` and the Dockerfile entrypoint
  to run Ecto migrations before starting the application.

      # Run migrations
      bin/stackcoin eval "StackCoin.Release.migrate"

      # Rollback to a specific version
      bin/stackcoin eval "StackCoin.Release.rollback(StackCoin.Repo, 20250101000000)"
  """

  @app :stackcoin

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
