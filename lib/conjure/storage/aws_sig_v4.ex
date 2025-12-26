defmodule Conjure.Storage.AwsSigV4 do
  @moduledoc """
  AWS Signature Version 4 signing for S3 requests.

  This module implements the AWS Signature Version 4 algorithm for
  authenticating requests to S3-compatible services including:
  - AWS S3
  - Tigris (Fly.io)
  - MinIO
  - LocalStack

  ## Usage

      headers = Conjure.Storage.AwsSigV4.sign(
        method: :put,
        host: "s3.us-east-1.amazonaws.com",
        path: "/my-bucket/my-key",
        payload: "file content",
        region: "us-east-1",
        access_key: "AKIAIOSFODNN7EXAMPLE",
        secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      )

  ## See Also

  * [AWS Signature Version 4 Signing Process](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html)
  """

  @doc """
  Sign an HTTP request for AWS S3-compatible services.

  ## Options

  * `:method` - HTTP method atom (required): `:get`, `:put`, `:delete`, `:head`
  * `:host` - Target host (required): e.g., `"s3.us-east-1.amazonaws.com"`
  * `:path` - Request path (required): e.g., `"/bucket/key"`
  * `:query` - Query string (optional): e.g., `"list-type=2"`
  * `:payload` - Request body (optional): defaults to `""`
  * `:region` - AWS region (required): e.g., `"us-east-1"`
  * `:access_key` - AWS access key ID (required)
  * `:secret_key` - AWS secret access key (required)
  * `:service` - AWS service (optional): defaults to `"s3"`

  ## Returns

  List of headers to include in the request:
  - `Authorization` - AWS4-HMAC-SHA256 signature
  - `x-amz-date` - Request timestamp
  - `x-amz-content-sha256` - Payload hash
  - `Host` - Target host

  ## Example

      headers = Conjure.Storage.AwsSigV4.sign(
        method: :put,
        host: "s3.us-east-1.amazonaws.com",
        path: "/my-bucket/my-key",
        payload: "Hello, World!",
        region: "us-east-1",
        access_key: System.get_env("AWS_ACCESS_KEY_ID"),
        secret_key: System.get_env("AWS_SECRET_ACCESS_KEY")
      )

      Req.put("https://s3.us-east-1.amazonaws.com/my-bucket/my-key",
        body: "Hello, World!",
        headers: headers
      )
  """
  @spec sign(keyword()) :: [{String.t(), String.t()}]
  def sign(opts) do
    method = Keyword.fetch!(opts, :method) |> Atom.to_string() |> String.upcase()
    host = Keyword.fetch!(opts, :host)
    path = Keyword.fetch!(opts, :path)
    query = Keyword.get(opts, :query, "")
    payload = Keyword.get(opts, :payload, "")
    region = Keyword.fetch!(opts, :region)
    access_key = Keyword.fetch!(opts, :access_key)
    secret_key = Keyword.fetch!(opts, :secret_key)
    service = Keyword.get(opts, :service, "s3")

    now = DateTime.utc_now()
    date_stamp = format_date(now)
    amz_date = format_datetime(now)

    # Hash the payload
    payload_hash = hash_sha256(payload)

    # Create canonical headers (must be sorted)
    canonical_headers = [
      {"host", host},
      {"x-amz-content-sha256", payload_hash},
      {"x-amz-date", amz_date}
    ]

    signed_headers = Enum.map_join(canonical_headers, ";", &elem(&1, 0))

    canonical_headers_str = Enum.map_join(canonical_headers, "", fn {k, v} -> "#{k}:#{v}\n" end)

    # Create canonical request
    canonical_request =
      [
        method,
        uri_encode_path(path),
        query,
        canonical_headers_str,
        signed_headers,
        payload_hash
      ]
      |> Enum.join("\n")

    # Create string to sign
    credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

    string_to_sign =
      [
        "AWS4-HMAC-SHA256",
        amz_date,
        credential_scope,
        hash_sha256(canonical_request)
      ]
      |> Enum.join("\n")

    # Calculate signature
    signing_key = get_signature_key(secret_key, date_stamp, region, service)
    signature = hmac_sha256(signing_key, string_to_sign) |> Base.encode16(case: :lower)

    # Build authorization header
    authorization =
      "AWS4-HMAC-SHA256 " <>
        "Credential=#{access_key}/#{credential_scope}, " <>
        "SignedHeaders=#{signed_headers}, " <>
        "Signature=#{signature}"

    [
      {"Authorization", authorization},
      {"x-amz-date", amz_date},
      {"x-amz-content-sha256", payload_hash},
      {"Host", host}
    ]
  end

  @doc """
  Create presigned URL for S3 object.

  ## Options

  Same as `sign/1` plus:
  * `:expires_in` - URL expiration in seconds (default: 3600)

  ## Returns

  Presigned URL string.
  """
  @spec presign_url(keyword()) :: String.t()
  def presign_url(opts) do
    host = Keyword.fetch!(opts, :host)
    path = Keyword.fetch!(opts, :path)
    region = Keyword.fetch!(opts, :region)
    access_key = Keyword.fetch!(opts, :access_key)
    secret_key = Keyword.fetch!(opts, :secret_key)
    expires_in = Keyword.get(opts, :expires_in, 3600)
    service = Keyword.get(opts, :service, "s3")
    scheme = Keyword.get(opts, :scheme, "https")

    now = DateTime.utc_now()
    date_stamp = format_date(now)
    amz_date = format_datetime(now)

    credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"
    credential = "#{access_key}/#{credential_scope}"

    # Query parameters for presigned URL
    query_params = [
      {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
      {"X-Amz-Credential", credential},
      {"X-Amz-Date", amz_date},
      {"X-Amz-Expires", to_string(expires_in)},
      {"X-Amz-SignedHeaders", "host"}
    ]

    query_string =
      query_params
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("&", fn {k, v} -> "#{uri_encode(k)}=#{uri_encode(v)}" end)

    # Canonical request for presigned URL
    canonical_request =
      [
        "GET",
        uri_encode_path(path),
        query_string,
        "host:#{host}\n",
        "host",
        "UNSIGNED-PAYLOAD"
      ]
      |> Enum.join("\n")

    # String to sign
    string_to_sign =
      [
        "AWS4-HMAC-SHA256",
        amz_date,
        credential_scope,
        hash_sha256(canonical_request)
      ]
      |> Enum.join("\n")

    # Signature
    signing_key = get_signature_key(secret_key, date_stamp, region, service)
    signature = hmac_sha256(signing_key, string_to_sign) |> Base.encode16(case: :lower)

    "#{scheme}://#{host}#{path}?#{query_string}&X-Amz-Signature=#{signature}"
  end

  # Private helpers

  defp hash_sha256(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp hmac_sha256(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  defp get_signature_key(secret_key, date_stamp, region, service) do
    ("AWS4" <> secret_key)
    |> then(&hmac_sha256(&1, date_stamp))
    |> then(&hmac_sha256(&1, region))
    |> then(&hmac_sha256(&1, service))
    |> then(&hmac_sha256(&1, "aws4_request"))
  end

  defp format_date(datetime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_iso8601(:basic)
  end

  defp format_datetime(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[:-]/, "")
    |> String.replace("+00:00", "Z")
  end

  defp uri_encode(string) do
    URI.encode(string, &uri_unreserved_char?/1)
  end

  defp uri_encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &uri_encode/1)
  end

  defp uri_unreserved_char?(char) do
    char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?., ?-, ?~]
  end
end
