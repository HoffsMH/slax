defmodule SlaxWeb.BlockerController do
  use SlaxWeb, :controller
  alias Slax.Slack
  alias Slax.Github

  plug(Slax.Plugs.VerifySlackToken, token: :blocker)
  plug(Slax.Plugs.VerifyUser)

  alias Slax.Commands.{GithubCommands}

  @moduledoc """
  Entry point to interact with blockerbot functionality.
  Eventually we may want to think about adding slash commands to handle various configuration tasks, such as:
  > /blocker in-progress-min=2 #Set the mininum threshold for how long something is a blocker to 2 days
  > /blocker turn-on/off #Turn on/off the blockerbot for a particular channel and/or project
  """

  def start(conn, %{"response_url" => response_url, "text" => "get-in-progress-issues", "channel_name" => channel_name}) do
    do_start(
      conn,
      :handle_get_blockers_request,
      [
        conn.assigns.current_user.github_access_token,
        response_url,
        channel_name
      ]
    )
  end

  def start(conn, _) do
    text(conn, """
    *Blocker commands:*
    /blocker get-in-progress-issues  -- _Gets all issues that are in progress for whatever project channel (ie. repo) you are calling it from_
    """)
  end

  defp do_start(conn, func, args) do
    Task.start_link(__MODULE__, func, args)
    send_resp(conn, 201, "")
  end

  def handle_get_blockers_request(github_access_token, response_url, channel_name) do
    repo_names =
      from(
        pc in Slax.ProjectChannel,
        where: pc.channel_name == ^channel_name,
      )
      |> join(:inner, [pc], p in assoc(pc, :project))
      |> select([_, pc], pc.name)
      |> Repo.all()

    case repo_names do
      [] ->
        Slack.send_message(response_url, %{
          response_type: "in_channel",
          text: "No repos for this channel."
        })
      _ ->
        Enum.each(repo_names, fn repo_name ->
          params = %{
            repo: repo_name,
            access_token: github_access_token,
            org: Application.get_env(:slax, Slax.Github)[:org_name]
          }

          issues = Github.fetch_issues(params)
          events = Github.fetch_issues_events(params, issues) |> GithubCommands.filter_issues_events()

          formatted_response =
            issues
            |> GithubCommands.filter_issues(events)
            |> GithubCommands.format_issues()

          Slack.send_message(response_url, %{
            response_type: "in_channel",
            text: formatted_response
          })
        end)
    end
  end
end
