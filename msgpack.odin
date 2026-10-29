/*
Package msgpack encodes and decodes MessagePack, the compact binary
serialization format described at https://msgpack.org.

The package has three layers. Pick the one that fits the job:

- A streaming Encoder and Decoder that read and write one MessagePack item
  at a time: `write_int`, `write_str`, `read_map_header`, `skip` and friends.
- A dynamic Value type that holds any MessagePack document: `decode_value`,
  `encode_value` and `value_destroy`.
- Reflection-based marshal and unmarshal that map Odin types, including
  structs with `msgpack:"name,omitempty"` tags, to MessagePack and back.

The package supports the full format family: nil, bool, every integer width,
float32 and float64, str, bin, array, map, extension types and the timestamp
extension (type -1).

Every allocating procedure takes an explicit allocator and documents who owns
the result. The package keeps no global mutable state; an Encoder or Decoder
is safe to use from one thread at a time.

Example:
	import "core:fmt"
	import msgpack "shared:msgpack"

	Point :: struct {
		x: int,
		y: int,
		label: string `msgpack:"name"`,
	}

	main :: proc() {
		data, err := msgpack.marshal(Point{1, 2, "origin"})
		if err != nil {
			return
		}
		defer delete(data)

		p: Point
		if msgpack.unmarshal(data, &p) == nil {
			defer msgpack.destroy(&p)
			fmt.println(p)
		}
	}
*/
package msgpack

import "base:runtime"

// DEFAULT_MAX_DEPTH is the nesting depth that decoders and marshal accept by default.
DEFAULT_MAX_DEPTH :: 512

// TIMESTAMP_EXT_TYPE is the extension type that MessagePack reserves for timestamps.
TIMESTAMP_EXT_TYPE :: -1

// Decode_Error lists the ways that reading MessagePack can fail.
Decode_Error :: enum {
	None,
	// The input ended in the middle of an item, or a length points past the end.
	Unexpected_Eof,
	// The input contains the byte 0xc1, which MessagePack never uses.
	Invalid_Format,
	// The next item has a different type than the one requested.
	Type_Mismatch,
	// An integer doesn't fit in the destination type.
	Integer_Overflow,
	// A timestamp extension has a bad length or nanoseconds of 1e9 or more.
	Invalid_Timestamp,
	// Arrays and maps nest deeper than the decoder's `max_depth`.
	Max_Depth_Exceeded,
	// Bytes remain after the single top-level item.
	Trailing_Data,
	// A map that decodes into an Odin map repeats a key.
	Duplicate_Key,
	// An array or bin is longer than the fixed-size destination.
	Too_Many_Elements,
	// The destination type has no MessagePack mapping, for example a procedure.
	Unsupported_Destination,
	// The destination pointer passed to unmarshal is nil.
	Nil_Destination,
}

// Encode_Error lists the ways that writing MessagePack can fail.
Encode_Error :: enum {
	None,
	// A length is negative or larger than 2^32 - 1, the MessagePack limit.
	Invalid_Length,
	// An integer is outside the range that MessagePack can represent.
	Integer_Out_Of_Range,
	// A timestamp has nanoseconds of 1e9 or more.
	Bad_Timestamp,
	// The value nests deeper than DEFAULT_MAX_DEPTH, which usually means a pointer cycle.
	Nesting_Too_Deep,
	// The value's type has no MessagePack mapping, for example a procedure or a raw pointer.
	Unsupported_Type,
}

/*
Error is the compound error type that every fallible procedure in this package
returns. `nil` means success. Compare it against a specific variant, for
example `msgpack.Error(msgpack.Decode_Error.Unexpected_Eof)`, or use a type
switch to tell decode, encode and allocator failures apart.
*/
Error :: union #shared_nil {
	Decode_Error,
	Encode_Error,
	runtime.Allocator_Error,
}

/*
Kind is the MessagePack type family of the next item in a Decoder, as
reported by peek_kind.
*/
Kind :: enum {
	Nil,
	Bool,
	Int,
	Float,
	String,
	Binary,
	Array,
	Map,
	// Any extension type other than the timestamp.
	Extension,
	// The timestamp extension, type -1.
	Timestamp,
}

/*
Timestamp is a point in time as MessagePack's timestamp extension stores it:
seconds since the Unix epoch plus a nanosecond part in `[0, 1e9)`.
*/
Timestamp :: struct {
	seconds:     i64,
	nanoseconds: u32,
}

/*
Extension is an application-defined MessagePack extension: a signed type
code and opaque payload bytes. Types 0 to 127 belong to applications;
negative types belong to MessagePack itself.
*/
Extension :: struct {
	type: i8,
	data: []byte,
}

// Format bytes from the MessagePack specification.
@(private) FMT_NIL           :: 0xc0
@(private) FMT_NEVER         :: 0xc1
@(private) FMT_FALSE         :: 0xc2
@(private) FMT_TRUE          :: 0xc3
@(private) FMT_BIN8          :: 0xc4
@(private) FMT_BIN16         :: 0xc5
@(private) FMT_BIN32         :: 0xc6
@(private) FMT_EXT8          :: 0xc7
@(private) FMT_EXT16         :: 0xc8
@(private) FMT_EXT32         :: 0xc9
@(private) FMT_FLOAT32       :: 0xca
@(private) FMT_FLOAT64       :: 0xcb
@(private) FMT_UINT8         :: 0xcc
@(private) FMT_UINT16        :: 0xcd
@(private) FMT_UINT32        :: 0xce
@(private) FMT_UINT64        :: 0xcf
@(private) FMT_INT8          :: 0xd0
@(private) FMT_INT16         :: 0xd1
@(private) FMT_INT32         :: 0xd2
@(private) FMT_INT64         :: 0xd3
@(private) FMT_FIXEXT1       :: 0xd4
@(private) FMT_FIXEXT2       :: 0xd5
@(private) FMT_FIXEXT4       :: 0xd6
@(private) FMT_FIXEXT8       :: 0xd7
@(private) FMT_FIXEXT16      :: 0xd8
@(private) FMT_STR8          :: 0xd9
@(private) FMT_STR16         :: 0xda
@(private) FMT_STR32         :: 0xdb
@(private) FMT_ARRAY16       :: 0xdc
@(private) FMT_ARRAY32       :: 0xdd
@(private) FMT_MAP16         :: 0xde
@(private) FMT_MAP32         :: 0xdf
@(private) FMT_FIXMAP        :: 0x80
@(private) FMT_FIXARRAY      :: 0x90
@(private) FMT_FIXSTR        :: 0xa0
@(private) FMT_NEG_FIXINT    :: 0xe0

// MAX_LENGTH is the largest length that a MessagePack str, bin, array, map or ext can declare.
MAX_LENGTH :: 0xffff_ffff
