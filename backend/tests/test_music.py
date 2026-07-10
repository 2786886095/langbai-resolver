from app.models import MusicSearchResult
from app.services.music import OpenMusicService


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
    )


def test_music_search_merges_sources_and_deduplicates() -> None:
    service = OpenMusicService()
    service._search_archive = lambda _q, _l: [  # type: ignore[method-assign]
        _result("internet_archive:1", "Shared Song", "internet_archive", "Archive", can_download=True)
    ]
    service._search_commons = lambda _q, _l: [  # type: ignore[method-assign]
        _result("wikimedia_commons:2", "Commons Song", "wikimedia_commons", "Commons", can_download=True)
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
