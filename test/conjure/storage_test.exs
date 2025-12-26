defmodule Conjure.StorageTest do
  use ExUnit.Case, async: true

  alias Conjure.Storage

  describe "generate_session_id/0" do
    test "generates unique IDs" do
      id1 = Storage.generate_session_id()
      id2 = Storage.generate_session_id()

      assert id1 != id2
      assert is_binary(id1)
      assert String.length(id1) >= 10
    end

    test "generates URL-safe IDs" do
      id = Storage.generate_session_id()

      # Should only contain URL-safe base64 characters
      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, id)
    end
  end

  describe "build_file_ref/3" do
    test "builds file ref with computed defaults" do
      content = "hello world"
      ref = Storage.build_file_ref("test.txt", content)

      assert ref.path == "test.txt"
      assert ref.size == byte_size(content)
      assert ref.content_type == "text/plain"
      assert ref.checksum != nil
      assert ref.storage_url == nil
      assert %DateTime{} = ref.created_at
    end

    test "respects content_type override" do
      ref = Storage.build_file_ref("file.bin", "data", content_type: "application/pdf")
      assert ref.content_type == "application/pdf"
    end

    test "respects storage_url option" do
      ref =
        Storage.build_file_ref("file.txt", "data", storage_url: "https://s3.example.com/file.txt")

      assert ref.storage_url == "https://s3.example.com/file.txt"
    end

    test "computes consistent checksums" do
      content = "test content"
      ref1 = Storage.build_file_ref("a.txt", content)
      ref2 = Storage.build_file_ref("b.txt", content)

      assert ref1.checksum == ref2.checksum
    end
  end

  describe "guess_content_type/1" do
    test "returns correct MIME types for common extensions" do
      assert Storage.guess_content_type("report.xlsx") ==
               "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      assert Storage.guess_content_type("document.pdf") == "application/pdf"
      assert Storage.guess_content_type("data.json") == "application/json"
      assert Storage.guess_content_type("readme.txt") == "text/plain"
      assert Storage.guess_content_type("data.csv") == "text/csv"
      assert Storage.guess_content_type("page.html") == "text/html"
      assert Storage.guess_content_type("image.png") == "image/png"
      assert Storage.guess_content_type("photo.jpg") == "image/jpeg"
      assert Storage.guess_content_type("archive.zip") == "application/zip"
    end

    test "handles uppercase extensions" do
      assert Storage.guess_content_type("FILE.PDF") == "application/pdf"
      assert Storage.guess_content_type("DATA.JSON") == "application/json"
    end

    test "returns octet-stream for unknown extensions" do
      assert Storage.guess_content_type("file.xyz") == "application/octet-stream"
      assert Storage.guess_content_type("noextension") == "application/octet-stream"
    end
  end

  describe "compute_checksum/1" do
    test "computes SHA256 checksum" do
      # Known SHA256 hash of "hello"
      expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
      assert Storage.compute_checksum("hello") == expected
    end

    test "returns lowercase hex string" do
      checksum = Storage.compute_checksum("test")
      assert checksum == String.downcase(checksum)
      assert String.length(checksum) == 64
    end
  end
end
