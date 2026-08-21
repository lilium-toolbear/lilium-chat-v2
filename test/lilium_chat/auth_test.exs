defmodule LiliumChat.AuthTest do
  use ExUnit.Case, async: true

  alias LiliumChat.Auth
  alias LiliumChat.Errors.ApiError
  import LiliumChat.TestJWT

  @uid "00000000-0000-7000-8000-000000000101"

  test "accepts a self-session browser token" do
    assert {:ok, %Auth.Identity{user_id: user_id, is_admin: false}} =
             Auth.verify(sign(%{"sub" => @uid}), secret())

    assert user_id == @uid
  end

  test "accepts admin claim as is_admin true (strict === true)" do
    assert {:ok, %Auth.Identity{is_admin: true}} =
             Auth.verify(sign(%{"sub" => @uid, "admin" => true}), secret())

    assert {:ok, %Auth.Identity{is_admin: false}} =
             Auth.verify(sign(%{"sub" => @uid, "admin" => "true"}), secret())

    assert {:ok, %Auth.Identity{is_admin: false}} =
             Auth.verify(sign(%{"sub" => @uid, "admin" => 1}), secret())
  end

  test "accepts self-session with explicit owner_user_id == sub and effective == sub" do
    assert {:ok, %Auth.Identity{user_id: user_id}} =
             Auth.verify(
               sign(%{
                 "sub" => @uid,
                 "owner_user_id" => @uid,
                 "effective_account_user_id" => @uid
               }),
               secret()
             )

    assert user_id == @uid
  end

  test "accepts owner/effective claims that JS-stringify to sub (numeric id parity)" do
    assert {:ok, _} = Auth.verify(sign(%{"sub" => "123", "owner_user_id" => 123}), secret())
  end

  test "client_id present → MACHINE_TOKEN_NOT_ALLOWED (401)" do
    assert {:error,
            %ApiError{
              code: "MACHINE_TOKEN_NOT_ALLOWED",
              http_status: 401,
              message: "Machine tokens are not allowed"
            }} =
             Auth.verify(sign(%{"sub" => @uid, "client_id" => "client-1"}), secret())
  end

  test "client_id null → accepted (JS !== undefined && !== null)" do
    assert {:ok, _} = Auth.verify(sign(%{"sub" => @uid, "client_id" => nil}), secret())
  end

  test "managed_session=true → SESSION_NOT_ALLOWED (403)" do
    assert {:error,
            %ApiError{
              code: "SESSION_NOT_ALLOWED",
              http_status: 403,
              message: "Chat requires a direct user session"
            }} =
             Auth.verify(sign(%{"sub" => @uid, "managed_session" => true}), secret())
  end

  test "managed_session string 'true' → accepted (JS === true strictness)" do
    assert {:ok, _} = Auth.verify(sign(%{"sub" => @uid, "managed_session" => "true"}), secret())
  end

  test "owner != sub (effective == sub) → SESSION_NOT_ALLOWED" do
    assert {:error, %ApiError{code: "SESSION_NOT_ALLOWED"}} =
             Auth.verify(
               sign(%{
                 "sub" => @uid,
                 "owner_user_id" => "u-owner",
                 "effective_account_user_id" => @uid
               }),
               secret()
             )
  end

  test "owner != sub and effective != sub → SESSION_NOT_ALLOWED" do
    assert {:error, %ApiError{code: "SESSION_NOT_ALLOWED"}} =
             Auth.verify(
               sign(%{
                 "sub" => @uid,
                 "owner_user_id" => "u-owner",
                 "effective_account_user_id" => "u-other"
               }),
               secret()
             )
  end

  test "only effective != sub → SESSION_NOT_ALLOWED" do
    assert {:error, %ApiError{code: "SESSION_NOT_ALLOWED"}} =
             Auth.verify(
               sign(%{"sub" => @uid, "effective_account_user_id" => "u-other"}),
               secret()
             )
  end

  test "only owner != sub → SESSION_NOT_ALLOWED" do
    assert {:error, %ApiError{code: "SESSION_NOT_ALLOWED"}} =
             Auth.verify(sign(%{"sub" => @uid, "owner_user_id" => "u-owner"}), secret())
  end

  test "owner_user_id null (present) → SESSION_NOT_ALLOWED (JS String(null) = 'null' ≠ sub)" do
    assert {:error, %ApiError{code: "SESSION_NOT_ALLOWED"}} =
             Auth.verify(sign(%{"sub" => @uid, "owner_user_id" => nil}), secret())
  end

  test "expired token → UNAUTHORIZED (401)" do
    exp = System.system_time(:second) - 10

    assert {:error, %ApiError{code: "UNAUTHORIZED", http_status: 401}} =
             Auth.verify(sign(%{"sub" => @uid}, exp: exp), secret())
  end

  test "bad signature → UNAUTHORIZED" do
    token = sign(%{"sub" => @uid}, secret: "wrong-secret")
    assert {:error, %ApiError{code: "UNAUTHORIZED"}} = Auth.verify(token, secret())
  end

  test "missing sub → UNAUTHORIZED" do
    assert {:error, %ApiError{code: "UNAUTHORIZED"}} = Auth.verify(sign(%{}, exp: nil), secret())
  end

  test "non-string / empty sub → UNAUTHORIZED" do
    assert {:error, %ApiError{code: "UNAUTHORIZED"}} =
             Auth.verify(sign(%{"sub" => 123}), secret())

    assert {:error, %ApiError{code: "UNAUTHORIZED"}} = Auth.verify(sign(%{"sub" => ""}), secret())
  end

  test "malformed token → UNAUTHORIZED" do
    assert {:error, %ApiError{code: "UNAUTHORIZED"}} = Auth.verify("not.a.jwt", secret())
    assert {:error, %ApiError{code: "UNAUTHORIZED"}} = Auth.verify("", secret())
  end

  test "token without exp claim is accepted (jose parity: exp optional)" do
    assert {:ok, _} = Auth.verify(sign(%{"sub" => @uid}, exp: nil), secret())
  end

  test "nil/empty secret → UNAUTHORIZED" do
    assert {:error, %ApiError{code: "UNAUTHORIZED"}} = Auth.verify(sign(%{"sub" => @uid}), nil)
    assert {:error, %ApiError{code: "UNAUTHORIZED"}} = Auth.verify(sign(%{"sub" => @uid}), "")
  end

  test "machine check precedes session checks (client_id + managed_session → MACHINE_TOKEN_NOT_ALLOWED)" do
    assert {:error, %ApiError{code: "MACHINE_TOKEN_NOT_ALLOWED"}} =
             Auth.verify(
               sign(%{"sub" => @uid, "client_id" => "c1", "managed_session" => true}),
               secret()
             )
  end
end
