# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import zipfile
import uniarchive

def test_python_created_zip(tmp_path):
    path = tmp_path / "python.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("hello.txt", b"hello")
    assert uniarchive.entry_count(str(path)) == 1
    assert uniarchive.names(str(path)) == ["hello.txt"]
    assert uniarchive.read_entry(str(path), "hello.txt") == b"hello"
    destination = tmp_path / "output"
    uniarchive.extract(str(path), str(destination))
    assert (destination / "hello.txt").read_bytes() == b"hello"

def test_uniarchive_create_and_selective_extract(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    (source / "one.txt").write_bytes(b"one")
    (source / "two.txt").write_bytes(b"two")
    path = tmp_path / "created.zip"
    uniarchive.create(str(path), [str(source)], store=True)
    assert uniarchive.names(str(path)) == [
        "source/", "source/one.txt", "source/two.txt"]
    with zipfile.ZipFile(path) as archive:
        assert all(info.compress_type == 0 for info in archive.infolist())
    destination = tmp_path / "selected"
    uniarchive.extract(str(path), str(destination), ["source/one.txt"])
    assert (destination / "source" / "one.txt").read_bytes() == b"one"
    assert not (destination / "source" / "two.txt").exists()
