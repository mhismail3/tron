"""iOS reference graph from this worktree's Xcode index store (tools/layers/README.md "iOS").

The store is written by `scripts/tron-ios-test build` into the worktree's products
directory. It is trusted only when that directory's build stamp equals this
worktree's current source identity on a clean tree. Otherwise it is refused, never
replaced by a guess.
"""
from __future__ import annotations

import ctypes
import importlib.util
import json
import os
import subprocess
from collections import defaultdict
from pathlib import Path

DEFINITION, REFERENCE, RECORD = 1 << 1, 1 << 2, 2
LIBRARY = "Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"


class IndexError_(Exception):
    pass


class _Str(ctypes.Structure):
    _fields_ = [("data", ctypes.c_char_p), ("length", ctypes.c_size_t)]


def _text(ref: _Str) -> str:
    return ctypes.string_at(ref.data, ref.length).decode("utf-8", "surrogateescape") if ref.data else ""


def _identity_module(root: Path):
    spec = importlib.util.spec_from_file_location("ios_test_build_identity", root / "scripts/ios-test-build-identity.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fresh_store(root: Path) -> Path:
    """The products' index store, once its build stamp proves it matches this clean worktree."""
    identities = _identity_module(root)
    try:
        current = identities.identity(root)
    except identities.IdentityError as error:
        raise IndexError_(f"cannot read this worktree's source identity: {error}") from error
    products = Path(os.environ.get("TRON_IOS_TEST_DERIVED_DATA") or
                    Path.home() / "Library/Developer/Tron/ios/test-derived-data" / current["worktree_key"])
    rebuild = "run scripts/tron-ios-test build"
    if current["dirty"]:
        raise IndexError_(f"the worktree has uncommitted or untracked changes; commit them, then {rebuild}")
    try:
        stored = json.loads(identities.identity_path(products).read_text())
    except (OSError, ValueError) as error:
        raise IndexError_(f"no readable build stamp in {products} ({error}); {rebuild}") from error
    if not isinstance(stored, dict) or stored.get("schema") != identities.SCHEMA:
        raise IndexError_(f"unrecognized build stamp in {products}; {rebuild}")
    stale = [field for field in identities.IDENTITY_FIELDS if stored.get(field) != current[field]]
    if stale:
        raise IndexError_(f"stale index: built from revision {str(stored.get('revision'))[:12]}"
                          f"{' (dirty)' if stored.get('dirty') else ''}, this worktree is at "
                          f"{current['revision'][:12]} (differs in {', '.join(stale)}); {rebuild}")
    store = products / "Index.noindex" / "DataStore"
    if not store.is_dir():
        raise IndexError_(f"the stamped build has no index store at {store}; {rebuild}")
    return store


def _library() -> ctypes.CDLL:
    developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    path = Path(developer) / LIBRARY
    if not path.is_file():
        raise IndexError_(f"Xcode's libIndexStore is missing at {path}")
    lib = ctypes.CDLL(str(path))
    v = ctypes.c_void_p
    for name, result, args in (
        ("indexstore_store_create", v, [ctypes.c_char_p, ctypes.POINTER(v)]),
        ("indexstore_error_get_description", ctypes.c_char_p, [v]),
        ("indexstore_unit_reader_create", v, [v, ctypes.c_char_p, ctypes.POINTER(v)]),
        ("indexstore_unit_dependency_get_kind", ctypes.c_int, [v]),
        ("indexstore_unit_dependency_get_name", _Str, [v]),
        ("indexstore_unit_dependency_get_filepath", _Str, [v]),
        ("indexstore_record_reader_create", v, [v, ctypes.c_char_p, ctypes.POINTER(v)]),
        ("indexstore_occurrence_get_symbol", v, [v]),
        ("indexstore_occurrence_get_roles", ctypes.c_uint64, [v]),
        ("indexstore_symbol_get_usr", _Str, [v]),
        ("indexstore_unit_reader_dispose", None, [v]),
        ("indexstore_record_reader_dispose", None, [v]),
        ("indexstore_store_dispose", None, [v]),
    ):
        function = getattr(lib, name)
        function.restype, function.argtypes = result, args
    return lib


def graph(root: Path, package: str, tracked: set) -> tuple[set, set]:
    """(file edges, indexed files) for tracked Swift files under `package`.

    An edge A -> B means A references a symbol (by USR) whose definition is in B.
    Units of files no longer tracked (left in the store by earlier builds) are ignored.
    """
    store_path = fresh_store(root)
    lib = _library()
    v = ctypes.c_void_p
    unit_applier = ctypes.CFUNCTYPE(ctypes.c_bool, v, _Str)
    item_applier = ctypes.CFUNCTYPE(ctypes.c_bool, v, v)
    lib.indexstore_store_units_apply_f.argtypes = [v, ctypes.c_uint, v, unit_applier]
    lib.indexstore_unit_reader_dependencies_apply_f.argtypes = [v, v, item_applier]
    lib.indexstore_record_reader_occurrences_apply_f.argtypes = [v, v, item_applier]
    error = v()
    store = lib.indexstore_store_create(str(store_path).encode(), ctypes.byref(error))
    if not store:
        raise IndexError_(f"cannot open {store_path}: {lib.indexstore_error_get_description(error)}")
    prefix = os.path.realpath(root) + os.sep
    units, records = [], {}
    lib.indexstore_store_units_apply_f(store, 0, None, unit_applier(lambda _, name: units.append(_text(name)) or True))

    def dependency(_, item):
        if lib.indexstore_unit_dependency_get_kind(item) == RECORD:
            path = os.path.realpath(_text(lib.indexstore_unit_dependency_get_filepath(item)))
            relative = path[len(prefix):] if path.startswith(prefix) else None
            if relative in tracked and relative.startswith(package + "/"):
                records[_text(lib.indexstore_unit_dependency_get_name(item))] = relative
        return True

    for unit in units:
        reader = lib.indexstore_unit_reader_create(store, unit.encode(), ctypes.byref(error))
        if reader:
            lib.indexstore_unit_reader_dependencies_apply_f(reader, None, item_applier(dependency))
            lib.indexstore_unit_reader_dispose(reader)
    definitions, references = defaultdict(set), defaultdict(set)
    for record, path in records.items():
        reader = lib.indexstore_record_reader_create(store, record.encode(), ctypes.byref(error))
        if not reader:
            raise IndexError_(f"unreadable index record {record} for {path}")

        def occurrence(_, item, path=path):
            roles = lib.indexstore_occurrence_get_roles(item)
            usr = _text(lib.indexstore_symbol_get_usr(lib.indexstore_occurrence_get_symbol(item)))
            if roles & DEFINITION:
                definitions[usr].add(path)
            elif roles & REFERENCE:
                references[path].add(usr)
            return True

        lib.indexstore_record_reader_occurrences_apply_f(reader, None, item_applier(occurrence))
        lib.indexstore_record_reader_dispose(reader)
    lib.indexstore_store_dispose(store)
    edges = {(source, target) for source, usrs in references.items() for usr in usrs
             for target in definitions.get(usr, ()) if target != source}
    return edges, set(records.values())
