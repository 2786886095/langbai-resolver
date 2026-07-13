import time
from concurrent.futures import ThreadPoolExecutor

from app.models import MusicSearchResult
from app.services.music import OpenMusicService, _license_allows_download
from app.services.music import _music_key


def test_only_explicit_open_licenses_enable_downloads() -> None:
    assert _license_allows_download("CC BY-SA 4.0")
    assert _license_allows_download("https://creativecommons.org/licenses/by/4.0/")
    assert _license_allows_download("Public Domain")
    assert not _license_allows_download("All rights reserved")
    assert not _license_allows_download("Copyright 2026 Example Records")
    assert not _license_allows_download(None)


def _result(
    identifier: str,
    title: str,
    source: str,
    source_label: str,
    *,
    creator: str = "Artist",
    can_download: bool = False,
) -> MusicSearchResult:
    return MusicSearchResult(
        identifier=identifier,
        title=title,
        creator=creator,
        item_url=f"https://example.com/{identifier}",
        source=source,
        source_label=source_label,
        can_download=can_download,
        preview_url=None if can_download else f"https://example.com/{identifier}.mp3",
    )


def test_music_search_merges_sources_and_deduplicates() -> None:
    service = OpenMusicService()
    service._search_archive = lambda _q, _l: [  # type: ignore[method-assign]
        _result(
            "internet_archive:1",
            "Shared Song",
            "internet_archive",
            "Archive",
            can_download=True,
        )
    ]
    service._search_openverse = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_commons = lambda _q, _l: [  # type: ignore[method-assign]
        _result(
            "wikimedia_commons:2",
            "Commons Song",
            "wikimedia_commons",
            "Commons",
            can_download=True,
        )
    ]
    service._search_audius = lambda _q, _l: [  # type: ignore[method-assign]
        _result("audius:3", "Audius Song", "audius", "Audius")
    ]
    service._search_musicbrainz = lambda _q, _l: [  # type: ignore[method-assign]
        _result("musicbrainz:4", "Shared Song", "musicbrainz", "MusicBrainz")
    ]
    service._search_itunes = lambda _q, _l: [  # type: ignore[method-assign]
        _result("apple_music:5", "Apple Song", "apple_music", "Apple Music")
    ]

    results = service.search("song", limit=20)

    assert {item.source for item in results} == {
        "internet_archive",
        "wikimedia_commons",
        "audius",
        "apple_music",
    }
    assert sum(item.title == "Shared Song" for item in results) == 1
    assert next(item for item in results if item.title == "Shared Song").can_download


def test_music_source_failures_are_reported_and_not_cached() -> None:
    service = OpenMusicService()
    service._search_archive = lambda _q, _l: [  # type: ignore[method-assign]
        _result("internet_archive:1", "Available", "internet_archive", "Archive")
    ]
    service._search_openverse = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_commons = lambda _q, _l: (_ for _ in ()).throw(  # type: ignore[method-assign]
        RuntimeError("provider down")
    )
    service._search_audius = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_musicbrainz = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_itunes = lambda _q, _l: []  # type: ignore[method-assign]

    results = service.search("test")
    statuses = {item.source: item for item in service.source_statuses()}

    assert results
    assert statuses["internet_archive"].available is True
    assert statuses["wikimedia_commons"].available is False
    assert "RuntimeError" in (statuses["wikimedia_commons"].detail or "")
    assert service._cache == {}


def test_same_music_query_uses_single_flight() -> None:
    service = OpenMusicService()
    calls = 0

    def archive(_query, _limit):
        nonlocal calls
        calls += 1
        time.sleep(0.05)
        return [
            _result(
                "internet_archive:1", "Single flight", "internet_archive", "Archive"
            )
        ]

    service._search_archive = archive  # type: ignore[method-assign]
    service._search_openverse = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_commons = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_audius = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_musicbrainz = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_itunes = lambda _q, _l: []  # type: ignore[method-assign]

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(service.search, "same query")
        second = executor.submit(service.search, "same query")
        assert first.result() == second.result()
    assert calls == 1


def test_music_key_removes_edition_and_featured_suffixes() -> None:
    assert _music_key("Same Song (Remastered 2026)", "Artist feat. Guest") == _music_key(
        "Same Song", "Artist"
    )


def test_metadata_only_music_results_are_hidden() -> None:
    service = OpenMusicService()
    service._search_openverse = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_archive = lambda _q, _l: [  # type: ignore[method-assign]
        MusicSearchResult(
            identifier="internet_archive:metadata",
            title="Metadata only",
            creator="Artist",
            item_url="https://example.com/metadata",
            source="internet_archive",
            source_label="Archive",
        )
    ]
    service._search_commons = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_audius = lambda _q, _l: []  # type: ignore[method-assign]
    service._search_itunes = lambda _q, _l: []  # type: ignore[method-assign]

    assert service.search("metadata") == []
