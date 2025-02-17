defmodule Bamboo.SendinBlueAdapterTest do
  use ExUnit.Case
  alias Bamboo.Email
  alias Bamboo.SendinBlueAdapter

  @config %{adapter: SendinBlueAdapter, api_key: "123_abc"}
  @config_with_bad_key %{adapter: SendinBlueAdapter, api_key: nil}

  defmodule FakeSendinBlue do
    use Plug.Router

    plug Plug.Parsers,
      # parsers: [:urlencoded, :multipart, :json],
      parsers: [:multipart, :json],
      pass: ["*/*"],
      json_decoder: Poison
    plug :match
    plug :dispatch

    def start_server(parent) do
      Agent.start_link(fn -> Map.new end, name: __MODULE__)
      Agent.update(__MODULE__, &Map.put(&1, :parent, parent))
      port = get_free_port()
      Application.put_env(:bamboo, :sendinblue_base_uri, "http://localhost:#{port}")
      Plug.Adapters.Cowboy.http __MODULE__, [], port: port, ref: __MODULE__
    end

    defp get_free_port do
      {:ok, socket} = :ranch_tcp.listen(port: 0)
      {:ok, port} = :inet.port(socket)
      :erlang.port_close(socket)
      port
    end

    def shutdown do
      Plug.Adapters.Cowboy.shutdown __MODULE__
    end

    post "/v3/smtp/email" do
      case Map.get(conn.params, "from") do
        "INVALID_EMAIL" -> conn |> send_resp(500, "Error!!") |> send_to_parent
        _ -> conn |> send_resp(200, "SENT") |> send_to_parent
      end
    end

    defp send_to_parent(conn) do
      parent = Agent.get(__MODULE__, fn(set) -> Map.get(set, :parent) end)
      send parent, {:fake_sendinblue, conn}
      conn
    end
  end

  setup do
    FakeSendinBlue.start_server(self())

    on_exit fn ->
      FakeSendinBlue.shutdown
    end

    :ok
  end

  test "raises if the api key is nil" do
    assert_raise ArgumentError, ~r/no API key set/, fn ->
      new_email(from: "foo@bar.com") |> SendinBlueAdapter.deliver(@config_with_bad_key)
    end

    assert_raise ArgumentError, ~r/no API key set/, fn ->
      SendinBlueAdapter.handle_config(%{})
    end
  end

  test "deliver/2 correctly formats reply-to from headers" do
    email = new_email(headers: %{"reply-to" => "foo@bar.com"})

    email |> SendinBlueAdapter.deliver(@config)

    assert_receive {:fake_sendinblue, %{params: params}}
    assert params["replyto"]["email"] == "foo@bar.com"
  end

  test "deliver/2 sends the to the right url" do
    new_email() |> SendinBlueAdapter.deliver(@config)

    assert_receive {:fake_sendinblue, %{request_path: request_path}}

    assert request_path == "/v3/smtp/email"
  end

  test "deliver/2 sends from, html and text body, subject, and headers" do
    email = new_email(
      from: {"From", "from@foo.com"},
      subject: "My Subject",
      text_body: "TEXT BODY",
      html_body: "HTML BODY",
    )
    |> Email.put_header("Reply-To", {"ReplyTo", "reply@foo.com"})

    email |> SendinBlueAdapter.deliver(@config)

    assert_receive {:fake_sendinblue, %{params: params, req_headers: headers}}

    assert params["sender"]["email"] == email.from |> elem(1)
    assert params["sender"]["name"] == email.from |> elem(0)
    assert params["subject"] == email.subject
    assert params["textContent"] == email.text_body
    assert params["htmlContent"] == email.html_body
    assert Enum.member?(headers, {"api-key", @config[:api_key]})
  end

  test "deliver/2 sends template params if set" do
    template_id = 1
    template_params = %{"username" => "Peter"}
    email = new_email(
      from: {"From", "from@foo.com"},
      subject: "My Subject",
      text_body: "TEXT BODY",
      html_body: "HTML BODY",
    )
    |> Email.put_header("Reply-To", {"ReplyTo", "reply@foo.com"})
    |> Email.put_private("template_id", template_id)
    |> Email.put_private("template_params", template_params)

    email |> SendinBlueAdapter.deliver(@config)

    assert_receive {:fake_sendinblue, %{params: params, req_headers: headers}}

    assert params["sender"]["email"] == nil
    assert params["sender"]["name"] == nil
    assert params["subject"] == nil
    assert params["textContent"] == email.text_body
    assert params["htmlContent"] == email.html_body
    assert params["templateId"] == template_id
    assert params["params"] == template_params
    assert Enum.member?(headers, {"api-key", @config[:api_key]})
  end

  test "deliver/2 correctly formats recipients" do
    email = new_email(
      to: [{"ToName", "to@bar.com"}, {nil, "noname@bar.com"}],
      cc: [{"CC", "cc@bar.com"}],
      bcc: [{"BCC", "bcc@bar.com"}],
    )

    email |> SendinBlueAdapter.deliver(@config)

    assert_receive {:fake_sendinblue, %{params: params}}
    assert params["to"] == [%{"email" => "to@bar.com", "name" => "ToName"}, %{"email" => "noname@bar.com", "name" => nil}]
    assert params["cc"] == [%{"email" => "cc@bar.com", "name" => "CC"}]
    assert params["bcc"] == [%{"email" => "bcc@bar.com", "name" => "BCC"}]
  end

  defp new_email(attrs \\ []) do
    attrs = Keyword.merge([from: "foo@bar.com", to: []], attrs)
    Email.new_email(attrs) |> Bamboo.Mailer.normalize_addresses
  end
end
