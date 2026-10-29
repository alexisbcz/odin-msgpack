# msgpack

[![CI](https://github.com/alexisbcz/odin-msgpack/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-msgpack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

A MessagePack encoder and decoder for Odin, with a dynamic `Value` type and reflection-based `marshal` and `unmarshal` for your own structs.

It covers the whole [MessagePack specification](https://github.com/msgpack/msgpack/blob/master/spec.md): nil, bool, every integer width, float32 and float64, str, bin, array, map, extension types and the timestamp extension (type -1). It has no dependencies outside Odin's `core` and `base` collections.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-msgpack libs/msgpack
```

```odin
import msgpack "libs/msgpack"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-msgpack ~/odin-shared/msgpack
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import msgpack "shared:msgpack"
```

## Quick start

Marshal a struct, then decode it back. Tags rename fields, skip them, or leave them out when empty.

```odin
package main

import "core:fmt"
import msgpack "shared:msgpack"

Player :: struct {
	name:     string,
	level:    int,
	tags:     []string,
	password: string `msgpack:"-"`,
	guild:    string `msgpack:"guild,omitempty"`,
}

main :: proc() {
	hero := Player {
		name  = "Ada",
		level = 7,
		tags  = {"mage", "healer"},
	}

	data, err := msgpack.marshal(hero)
	if err != nil {
		fmt.eprintln("marshal failed:", err)
		return
	}
	defer delete(data)

	back: Player
	if err = msgpack.unmarshal(data, &back); err != nil {
		fmt.eprintln("unmarshal failed:", err)
		return
	}
	defer msgpack.destroy(&back)
	fmt.println(back.name, back.level, back.tags)
}
```

## Dynamic values

When you don't know the schema, decode into a `Value`. The union's `nil` state is MessagePack nil.

```odin
package main

import "core:fmt"
import msgpack "shared:msgpack"

main :: proc() {
	// {"name": "odin", "stars": 9000}
	input := []byte{0x82, 0xa4, 'n', 'a', 'm', 'e', 0xa4, 'o', 'd', 'i', 'n', 0xa5, 's', 't', 'a', 'r', 's', 0xcd, 0x23, 0x28}

	doc, err := msgpack.decode_value(input)
	if err != nil {
		fmt.eprintln("decode failed:", err)
		return
	}
	defer msgpack.value_destroy(doc)

	if m, ok := doc.(msgpack.Map); ok {
		stars, _ := msgpack.map_get(m, "stars")
		fmt.println("stars:", stars.(i64))
	}
}
```

## Streaming

`Encoder` and `Decoder` work one item at a time. The decoder never allocates: `read_str`, `read_bin` and `read_ext` return slices that borrow the input.

```odin
package main

import "core:fmt"
import msgpack "shared:msgpack"

main :: proc() {
	e: msgpack.Encoder
	msgpack.encoder_init(&e)
	defer msgpack.encoder_destroy(&e)

	msgpack.write_array_header(&e, 2)
	msgpack.write_str(&e, "disk almost full")
	msgpack.write_timestamp(&e, {seconds = 1_700_000_000})

	d: msgpack.Decoder
	msgpack.decoder_init(&d, msgpack.encoder_bytes(&e))
	n, _ := msgpack.read_array_header(&d)
	message, _ := msgpack.read_str(&d)
	ts, _ := msgpack.read_timestamp(&d)
	fmt.println(n, message, ts.seconds)
}
```

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `marshal(v, allocator)` | Encode any Odin value | Yes | `delete` |
| `marshal_into(e, v)` | Append any Odin value to an `Encoder` | Into the encoder | `encoder_destroy` |
| `unmarshal(data, ptr, allocator)` | Decode one item into `ptr^` | Yes | `destroy` |
| `read_into(d, ptr, allocator)` | Decode the next item from a `Decoder` into `ptr^` | Yes | `destroy` |
| `destroy(ptr, allocator)` | Free what `unmarshal` allocated and zero `ptr^` | No | Not needed |
| `decode_value(data, allocator)` | Decode one item into a `Value` | Yes | `value_destroy` |
| `read_value(d, allocator)` | Decode the next item into a `Value` | Yes | `value_destroy` |
| `encode_value(v, allocator)` / `write_value(e, v)` | Encode a `Value` | Yes | `delete` / `encoder_destroy` |
| `value_equal(a, b)` / `map_get(m, key)` | Compare values, look up a string key | No | Not needed |
| `Encoder`, `encoder_init`, `write_*` | Write items one at a time | Yes | `encoder_destroy` |
| `Decoder`, `decoder_init`, `read_*`, `peek_kind`, `skip` | Read items one at a time | No | Not needed |
| `Timestamp`, `timestamp_from_time`, `timestamp_to_time` | The timestamp extension and `time.Time` | No | Not needed |
| `Error` | Union of `Decode_Error`, `Encode_Error` and `runtime.Allocator_Error` | No | Not needed |

### Type mapping

| Odin | MessagePack |
| --- | --- |
| `bool`, `b8` to `b64` | bool |
| Integers of any width and endianness, `rune`, enums | int, in the smallest format |
| `f16`, `f32` | float32 |
| `f64` | float64 |
| `string`, `cstring` | str |
| `[]byte`, `[dynamic]byte`, `[N]byte` | bin |
| Other slices, dynamic arrays, fixed arrays, enumerated arrays | array |
| `map[K]V` | map |
| Structs | map keyed by field name or tag name |
| Pointers, unions, `Maybe(T)` | the target or active variant, or nil |
| `Timestamp`, `time.Time` | timestamp extension |
| `Extension` | extension |

When it decodes, `unmarshal` also turns integers into floats, accepts str and bin for both strings and byte slices, and reads an enum from its member name. A union receives the item in the first variant of the item's own kind. When no variant has that kind, the first variant that one of these conversions reaches receives it.

### Struct tags

| Tag | Effect |
| --- | --- |
| `msgpack:"name"` | Use `name` as the map key |
| `msgpack:"-"` | Never encode or decode the field |
| `msgpack:",omitempty"` | Leave the field out when it's zero, or an empty string, slice or map |

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
odin run examples/stream
```

## Design notes

- Every allocating procedure takes `allocator := context.allocator` and says who owns the result.
- Fallible procedures return `Error`. The library never panics on bad input.
- When `unmarshal` or `read_into` fails, it leaves the destination alone and frees every partial allocation.
- The decoder checks every declared length against the remaining input before it allocates, so a short malicious message can't request gigabytes.
- `max_depth`, 512 by default, bounds nesting on decode. Marshal applies the same bound, which turns pointer cycles into an error.
- Decoding a map into an Odin map rejects duplicate keys with `.Duplicate_Key`. A `Value` keeps every entry, in input order.
- Odin maps have no defined iteration order, so marshal writes their entries in an unspecified order.
- The package keeps no global mutable state, so it's safe to use from several threads as long as each `Encoder`, `Decoder` and `Value` stays on one thread.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
