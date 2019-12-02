defmodule Bamboo.SendinBlueAdapter do
  @moduledoc """
  Sends email using SendinBlue's JSON API v3.0.

  Use this adapter to send emails through SendinBlue's API. Requires that an API
  key is set in the config.

  If you would like to add a replyto header to your email, then simply pass it in
  using the header property or put_header function like so:

      put_header("reply-to", "foo@bar.com")

  ## Example config

      # In config/config.exs, or config.prod.exs, etc.
      config :my_app, MyApp.Mailer,
        adapter: Bamboo.SendinBlueAdapter,
        api_key: "my_api_key"

      # Define a Mailer. Maybe in lib/my_app/mailer.ex
      defmodule MyApp.Mailer do
        use Bamboo.Mailer, otp_app: :my_app
      end
  """

  @default_base_uri "https://api.sendinblue.com"
  @send_message_path "/v3/smtp/email"
  @behaviour Bamboo.Adapter

  alias Bamboo.Email

  defmodule ApiError do
    defexception [:message]

    def exception(%{message: message}) do
      %ApiError{message: message}
    end

    def exception(%{params: params, response: response}) do
      filtered_params = params |> Plug.Conn.Query.decode |> Map.put("key", "[FILTERED]")

      message = """
      There was a problem sending the email through the SendinBlue API v3.0.

      Here is the response:

      #{inspect response, limit: :infinity}

      Here are the params we sent:

      #{inspect filtered_params, limit: :infinity}

      If you are deploying to Heroku and using ENV variables to handle your API key,
      you will need to explicitly export the variables so they are available at compile time.
      Add the following configuration to your elixir_buildpack.config:

      config_vars_to_export=(
        DATABASE_URL
        SENDINBLUE_API_KEY
      )
      """
      %ApiError{message: message}
    end
  end

  def deliver(email, config) do
    api_key = get_key(config)
    body = email |> to_sendinblue_body |> Poison.encode!
    url = [base_uri(), @send_message_path]

    case :hackney.post(url, headers(api_key), body, [:with_body]) do
      {:ok, status, _headers, response} when status > 299 ->
        raise(ApiError, %{params: body, response: response})
      {:ok, status, headers, response} ->
        %{status_code: status, headers: headers, body: response}
      {:error, reason} ->
        raise(ApiError, %{message: inspect(reason)})
    end
  end

  @doc false
  def handle_config(config) do
    if config[:api_key] in [nil, ""] do
      raise_api_key_error(config)
    else
      config
    end
  end

  defp get_key(config) do
    case Map.get(config, :api_key) do
      nil -> raise_api_key_error(config)
      key -> key
    end
  end

  defp raise_api_key_error(config) do
    raise ArgumentError, """
    There was no API key set for the SendinBlue adapter.

    * Here are the config options that were passed in:

    #{inspect config}
    """
  end

  defp headers(api_key) do
    [
      {"Content-Type", "application/json"},
      {"api-key", api_key}
    ]
  end

  defp to_sendinblue_body(%Email{} = email) do
    %{}
    |> put_from(email)
    |> put_to(email)
    |> put_reply_to(email)
    |> put_cc(email)
    |> put_bcc(email)
    |> put_subject(email)
    |> put_html_body(email)
    |> put_text_body(email)
    |> maybe_put_template_params(email)
  end

  defp maybe_put_template_params(params, %{
         private: %{"template_id" => template_id, "template_params" => template_params}
       }) do
    params
    |> Map.put(:templateId, template_id)
    |> Map.put(:params, template_params)
  end

  defp maybe_put_template_params(params, %{
         private: %{"template_id" => template_id}
       }) do
    params
    |> Map.put(:templateId, template_id)
  end

  defp maybe_put_template_params(params, _), do: params

  defp put_from(body, %Email{from: {name, email}}) do
    body
    |> Map.put(:sender, %{email: email, name: name})
  end

  defp put_to(body, %Email{to: to}) do
    body
    |> put_addresses(:to, Enum.map(to, fn {name, email} -> %{name: name, email: email} end))
  end

  defp put_cc(body, %Email{cc: []}), do: body
  defp put_cc(body, %Email{cc: nil}), do: body
  defp put_cc(body, %Email{cc: cc}) do
    body
    |> put_addresses(:cc, Enum.map(cc, fn {name, email} -> %{name: name, email: email} end))
  end

  defp put_bcc(body, %Email{bcc: []}), do: body
  defp put_bcc(body, %Email{bcc: nil}), do: body
  defp put_bcc(body, %Email{bcc: bcc}) do
    body
    |> put_addresses(:bcc, Enum.map(bcc, fn {name, email} -> %{name: name, email: email} end))
  end

  defp put_subject(body, %Email{subject: subject}), do: Map.put(body, :subject, subject)

  defp put_html_body(body, %Email{html_body: nil}), do: body
  defp put_html_body(body, %Email{html_body: html_body}), do: Map.put(body, :htmlContent, html_body)

  defp put_text_body(body, %Email{text_body: nil}), do: body
  defp put_text_body(body, %Email{text_body: text_body}), do: Map.put(body, :textContent, text_body)

  defp put_reply_to(body, %Email{headers: %{"reply-to" => email}} = _email) do
    Map.put(body, :replyto, %{email: email})
  end
  defp put_reply_to(body, _), do: body

  defp put_addresses(body, field, addresses), do: Map.put(body, field, addresses)

  # defp list_empty?([]), do: true
  # defp list_empty?(list) do
  #   Enum.all?(list, fn(el) -> el == "" || el == nil end)
  # end

  defp base_uri do
    Application.get_env(:bamboo, :sendinblue_base_uri) || @default_base_uri
  end
end
