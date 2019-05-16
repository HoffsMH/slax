defmodule Slax.Commands.GithubCommands do
  @moduledoc """
  Common functions for github commands
  """

  require IEx

  @steps [
    :project_name,
    :github_repo,
    :github_org_teams,
    :slack_channel,
    :lintron,
    :board_checker,
    :resuseable_stories
  ]

  alias Slax.{Github}

  def parse_project_name(results, text) do
    case Regex.run(~r/^[a-zA-Z0-9\-_]{3,21}$/, text) do
      [project_name] ->
        Map.put(results, :project_name, project_name)
        |> Map.update(:success, %{}, fn x -> Map.put(x, :project_name, "Project Name Parsed") end)

      _ ->
        Map.update(results, :errors, %{}, fn x ->
          Map.put(x, :project_name, "Invalid Project Name")
        end)
    end
  end

  def create_reusable_stories(
        %{project_name: project_name} = results,
        github_access_token,
        org_name,
        story_repo,
        story_paths
      ) do
    repo = "#{org_name}/#{project_name}"

    case Github.fetch_tree(%{access_token: github_access_token, repo: story_repo}) do
      {:ok, data} ->
        {blobs, tree_errors} = process_tree(data, story_repo, story_paths, github_access_token)
        {parsed_issues, parse_errors} = decode_blobs(blobs)

        {issue_ids, github_errors} =
          send_issues_to_github(repo, parsed_issues, github_access_token)

        errors = tree_errors ++ parse_errors ++ github_errors

        results =
          if length(errors) > 0 do
            errors =
              Enum.map(errors, fn {:error, path, message} -> "#{path}: #{message}" end)
              |> Enum.join("\n")

            Map.update(results, :errors, %{}, fn x -> Map.put(x, :resuseable_stories, errors) end)
          else
            results
          end

        results =
          if length(issue_ids) > 0 do
            Map.put(results, :reusable_stories, true)
            |> Map.update(:success, %{}, fn x ->
              Map.put(x, :resuseable_stories, "Reuseable Stories Created")
            end)
          else
            results
          end

        results

      {:error, message} ->
        Map.update(results, :errors, %{}, fn x -> Map.put(x, :resuseable_stories, message) end)
    end
  end

  defp process_tree(data, story_repo, story_paths, github_access_token) do
    Map.get(data, "tree", [])
    |> Enum.filter(fn x -> x["type"] == "blob" && String.ends_with?(x["path"], ".md") end)
    |> Enum.filter(fn x -> String.starts_with?(x["path"], Keyword.values(story_paths)) end)
    |> Enum.map(fn x ->
      case Github.fetch_blob(%{
             access_token: github_access_token,
             repo: story_repo,
             sha: x["sha"]
           }) do
        {:ok, data} ->
          {:ok, x["path"], data["content"]}

        {:error, message} ->
          {:error, x["path"], message}
      end
    end)
    |> Enum.split_with(fn
      {:ok, _, _} -> true
      {:error, _, _} -> false
    end)
  end

  defp decode_blobs(blobs) do
    blobs
    |> Enum.map(fn {:ok, path, content} ->
      with {:ok, issue} <- Base.decode64(content |> String.replace("\n", "")),
           {:ok, front_matter, body} <- YamlFrontMatter.parse(issue) do
        {:ok, path, front_matter, body}
      else
        :error ->
          {:error, path, "Unable to parse content"}

        {:error, message} ->
          {:error, path, message}
      end
    end)
    |> Enum.split_with(fn
      {:ok, _, _, _} -> true
      {:error, _, _} -> false
    end)
  end

  defp send_issues_to_github(repo, issues, github_access_token) do
    issues
    |> Enum.map(fn {:ok, path, front_matter, body} ->
      params = %{
        access_token: github_access_token,
        repo: repo,
        title: front_matter["title"],
        labels: List.wrap(Map.get(front_matter, "labels", [])),
        body: body
      }

      case Github.create_issue(params) do
        {:ok, data} ->
          {:ok, path, data}

        {:error, message} ->
          {:error, path, message}
      end
    end)
    |> Enum.split_with(fn
      {:ok, _, _} -> true
      {:error, _} -> false
    end)
  end

  @doc """
  Formats list of issues to be displayed nicely within Slack
  """
  def format_issues(results) do
    formatted_list = results
    |> Enum.map(&format_issue(&1))
    |> Enum.join("")

    date = DateTime.utc_now
    today = date
    |> Timex.weekday()
    |> Timex.day_name()
    ":snail:  *Latent Issues for #{today}, #{date.month}/#{date.day}* :slowpoke:
    Ways to take ownership:
    - Update ticket to correct column
    - Pair
    - Comment blockers (even if you don't know)
    - Escalate in channel (or another channel)\n\n"<> formatted_list
  end

  defp format_issue(issue) do
    labels =
      issue["labels"]
        |> Enum.map(& &1["name"])
        |> Enum.map(&(String.downcase(&1)))

    [status, status_as_of] = calculate_status_from_events(issue[:issue_events])
    {:ok, status_timestamp, _} = DateTime.from_iso8601(status_as_of)
    status_seconds = DateTime.diff(DateTime.utc_now(), status_timestamp)
    status_duration = Timex.Duration.from_seconds(status_seconds)

    if Enum.member?(["in progress", "in review", "qa", "uat"], status) do
      {:ok, timestamp, _} = DateTime.from_iso8601(issue["updated_at"])
      seconds = DateTime.diff(DateTime.utc_now(), timestamp)
      duration = Timex.Duration.from_seconds(seconds)

      assignees =
        case issue["assignees"] do
          [] ->
            "_No one._"
          _ ->
            issue["assignees"] |> Enum.map(&(&1["login"]))
        end

      events =
        issue[:issue_events]
        |> Enum.map(fn event ->
          "#{event["action"]} #{event["label"]["name"]} (#{event["created_at"]})"
        end)
        |> Enum.join(", ")

      {:ok, update_time_string} = Elixir.Timex.Format.DateTime.Formatters.Relative.format(timestamp, "{relative}")
      {:ok, status_time_string} = Elixir.Timex.Format.DateTime.Formatters.Relative.format(status_timestamp, "{relative}")

      "*#{issue["title"] |> String.strip()}* (#{issue[:org]}/#{issue[:repo]}##{issue["number"]})\n" <>
      "Status: #{status} for #{status_time_string}\n" <>
      "Last Updated: #{update_time_string}\n" <>
      "Assigned to: #{assignees}\n\n"
    else
      ""
    end
  end

  def calculate_status_from_events(events) do
    first_timestamp =
      case events do
        [] ->
          DateTime.utc_now() |> DateTime.to_iso8601()
        _ ->
          events
          |> Enum.at(0)
          |> Map.get("created_at")
      end

    events
    |> Enum.reduce([nil, first_timestamp], fn event, status ->
      case event["action"] do
        "labeled" ->
          [event["label"]["name"], event["created_at"]]
        "unlabeled" ->
          [old_status, _] = status
          if old_status == event["label"]["name"] do
            [nil, event["created_at"]]
          else
            status
          end
      end
    end)
  end

  @doc """
  Filters list of issues from issues events request
  threshold for filtering is based from
  set column threshold and labeled date
  """
  def filter_issues(issues, issues_events) do
    issues_events = filter_issues_events(issues_events)

    issues
    |> Enum.map(fn issue ->
      Map.put(issue, :issue_events, Enum.filter(issues_events, fn issue_event ->
        issue["number"] == issue_event["issue"]["number"]
      end))
    end)
  end

  def filter_issues_events(issue_events) do
    status_labels = ["in progress", "in review", "qa", "uat", "up next"]

    issue_events
    |> Enum.filter(&(Enum.member?(["labeled", "unlabeled"], &1["action"])))
    |> Enum.filter(fn event ->
        label_name =
          event["label"]["name"]
          |> String.downcase()
          |> String.strip()

        Enum.member?(status_labels, label_name)
    end)
  end

  @doc """
  Formats results map to be displayed nicely within Slack
  """
  @spec format_results(map) :: binary
  def format_results(results) do
    @steps
    |> Enum.map(&format_result(results, &1))
    |> Enum.join("\n")
  end

  defp format_result(results, key) do
    message =
      case results[key] do
        nil ->
          results[:errors][key]

        _ ->
          results[:success][key]
      end

    "#{key_to_display_name(key)}: #{message}"
  end

  defp key_to_display_name(key) do
    case key do
      :project_name ->
        "Project Name"

      :github_repo ->
        "Github"

      :github_org_teams ->
        "Github Teams"

      :slack_channel ->
        "Slack"

      :lintron ->
        "Lintron"

      :board_checker ->
        "Board Checker"

      :resuseable_stories ->
        "Reuseable Stories"

      _ ->
        ""
    end
  end
end
