"""Generate test vectors for CryptoService parity check.

Writes /tmp/ncm-mac-test/vectors.json with the canonical JSON strings directly,
plus the expected md5 + params. Swift driver just runs md5Hex + signEAPI from
those strings — no JSON encoder involved on the Swift side.
"""
import json, hashlib, sys
sys.path.insert(0, '/Users/mofan/Documents/MyProjects/ncm')
from src.core.crypto import sign_eapi, build_client_header

vectors = []

def add(name, path, payload):
    text = json.dumps(payload, separators=(',', ':'), ensure_ascii=False)
    digest = hashlib.md5(f"nobody{path}use{text}md5forencrypt".encode()).hexdigest()
    vectors.append({
        "name": name,
        "path": path,
        "canonical_json": text,
        "md5_digest": digest,
        "params": sign_eapi(path, payload),
    })

add("flat", "/api/v6/playlist/detail",
    {"id": 3778678, "n": 1000})

add("nested_header", "/api/v6/playlist/detail",
    {"id": 3778678, "n": 1000,
     "header": build_client_header(request_id="1791544593708",
                                   deviceId="35298d6e462ce9c909558bda74c01e4a")})

add("string_with_colon_space", "/api/lyric/feedback",
    {"id": 1, "comment": "hello: world", "tags": ["a: b", "c"]})

add("array_of_dict", "/api/song/like",
    {"trackId": 1, "like": True, "alg": "itembased_alg", "ids": [1, 2, 3]})

add("unicode", "/api/search",
    {"s": "周杰伦", "type": 1, "limit": 30})

add("song_url", "/api/song/enhance/player/url/v1",
    {"ids": "[1234567]", "br": 320000, "encodeType": "mp3",
     "header": build_client_header(request_id="1791544593708",
                                   deviceId="35298d6e462ce9c909558bda74c01e4a")})

# Also add a "compactJSON parity" check: feed the same payload through Swift
# OrderedDict encoder (constructed from pairs that match Python insertion
# order) and ensure bytes match canonical_json.
def add_with_payload(name, path, payload):
    text = json.dumps(payload, separators=(',', ':'), ensure_ascii=False)
    digest = hashlib.md5(f"nobody{path}use{text}md5forencrypt".encode()).hexdigest()
    # Recursively convert payload to a list of (key, value) pairs in insertion order.
    def to_pairs(obj):
        if isinstance(obj, dict):
            return [(k, to_pairs(v)) for k, v in obj.items()]
        if isinstance(obj, list):
            # Arrays of scalars stay as bare values (no tagged wrapper).
            # Arrays of dicts recursively encode each element.
            return [to_pairs(v) for v in obj]
        if obj is True: return ["bool", True]
        if obj is False: return ["bool", False]
        if obj is None: return ["null", None]
        if isinstance(obj, int): return ["int", obj]
        if isinstance(obj, float): return ["double", obj]
        if isinstance(obj, str): return obj  # bare string, not tagged
        raise ValueError(f"unknown {type(obj)}")

    vectors.append({
        "name": name + " [end-to-end encoder]",
        "path": path,
        "ordered_payload": to_pairs(payload),
        "expected_canonical_json": text,
        "expected_md5_digest": digest,
        "expected_params": sign_eapi(path, payload),
    })

add_with_payload("flat", "/api/v6/playlist/detail", {"id": 3778678, "n": 1000})
add_with_payload("nested_header", "/api/v6/playlist/detail",
    {"id": 3778678, "n": 1000,
     "header": build_client_header(request_id="1791544593708",
                                   deviceId="35298d6e462ce9c909558bda74c01e4a")})
add_with_payload("string_with_colon_space", "/api/lyric/feedback",
    {"id": 1, "comment": "hello: world", "tags": ["a: b", "c"]})
add_with_payload("unicode", "/api/search",
    {"s": "周杰伦", "type": 1, "limit": 30})

with open("/tmp/ncm-mac-test/vectors.json", "w") as f:
    json.dump(vectors, f, indent=2, ensure_ascii=False)
print(f"Wrote {len(vectors)} vectors")
