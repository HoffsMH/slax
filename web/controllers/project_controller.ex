defmodule Slax.ProjectController do
  use Slax.Web, :controller

  plug Slax.Plugs.VerifySlackToken, :project
  plug Slax.Plugs.VerifyUser

  def start(conn, %{"response_url" => response_url, "text" => "new " <> repo}) do
    Task.start_link(
      __MODULE__,
      :handle_new_project_request,
      [conn.assigns.current_user.github_access_token, repo, response_url]
    )

    send_resp(conn, 201, "")
  end

  def start(conn, _) do
    text conn, """
    *Project commands:*
    /project new <project_name>
    """
  end

  def handle_new_project_request(github_access_token, repo, response_url) do
    formatted_response = Slax.Project.new_project(String.trim(repo), github_access_token)
    |> Slax.Project.format_results

    Slack.send_message(response_url, %{
      response_type: "in_channel",
      text: formatted_response
    })
  end

end