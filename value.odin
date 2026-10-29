package msgpack

import "core:mem"
import "core:strings"

/*
Value holds any MessagePack document. The union's `nil` state is MessagePack
nil.

Integers decode as `i64` when they fit and as `u64` only above `max(i64)`.
Floats keep their width. Extension type -1 decodes as Timestamp; every other
extension decodes as Extension.

A Value that read_value or decode_value returns owns all of its strings,
bytes and nested containers. Free it with value_destroy and the same allocator.
*/
Value :: union {
	bool,
	i64,
	u64,
	f32,
	f64,
	string,
	Binary,
	Array,
	Map,
	Extension,
	Timestamp,
}

// Binary is a MessagePack bin item, kept apart from `string` so that the two stay distinct.
Binary :: distinct []byte

// Array is a MessagePack array.
Array :: distinct []Value

/*
Map is a MessagePack map. It keeps the pairs in input order, and it keeps
duplicate keys, because MessagePack allows keys of any type. Use map_get to
look up a string key.
*/
Map :: distinct []Map_Entry

// Map_Entry is one key and value pair of a Map.
Map_Entry :: struct {
	key:   Value,
	value: Value,
}

/*
decode_value decodes exactly one MessagePack item from `data` into a Value.

Inputs:
- data: the input; the result doesn't borrow from it.
- allocator: allocates every string, byte slice and container in the result.
- max_depth: the deepest nesting of arrays and maps to accept.

Returns:
- value: owned by the caller; free with `value_destroy(value, allocator)`.
- err: a Decode_Error, `.Trailing_Data` when bytes follow the item, or an allocator error.
*/
decode_value :: proc(data: []byte, allocator := context.allocator, max_depth := DEFAULT_MAX_DEPTH) -> (value: Value, err: Error) {
	d: Decoder
	decoder_init(&d, data, max_depth)
	value = read_value(&d, allocator) or_return
	if decoder_remaining(&d) != 0 {
		value_destroy(value, allocator)
		return nil, Decode_Error.Trailing_Data
	}
	return value, nil
}

/*
read_value consumes the next item from `d` into a Value. Unlike decode_value,
it leaves any following bytes for later reads.

Returns:
- value: owned by the caller; free with `value_destroy(value, allocator)`.
- err: a Decode_Error or an allocator error. Nothing leaks on failure.
*/
read_value :: proc(d: ^Decoder, allocator := context.allocator) -> (value: Value, err: Error) {
	start := d.pos
	defer if err != nil {
		value_destroy(value, allocator)
		value = nil
		d.pos = start
	}
	enter(d) or_return
	defer d.depth -= 1

	switch peek_kind(d) or_return {
	case .Nil:
		d.pos += 1
		return nil, nil
	case .Bool:
		return read_bool(d) or_return, nil
	case .Int:
		x := read_integer(d) or_return
		if x > i128(max(i64)) {
			return u64(x), nil
		}
		return i64(x), nil
	case .Float:
		if d.data[d.pos] == FMT_FLOAT32 {
			f := read_float(d) or_return
			return f32(f), nil
		}
		return read_float(d) or_return, nil
	case .String:
		s := read_str(d) or_return
		return strings.clone(s, allocator) or_return, nil
	case .Binary:
		b := read_bin(d) or_return
		return Binary(clone_bytes(b, allocator) or_return), nil
	case .Timestamp:
		return read_timestamp(d) or_return, nil
	case .Extension:
		type, data := read_ext(d) or_return
		return Extension{type, clone_bytes(data, allocator) or_return}, nil
	case .Array:
		n := read_array_header(d) or_return
		items := make(Array, n, allocator) or_return
		value = items
		for &item in items {
			item = read_value(d, allocator) or_return
		}
		return
	case .Map:
		n := read_map_header(d) or_return
		entries := make(Map, n, allocator) or_return
		value = entries
		for &entry in entries {
			entry.key = read_value(d, allocator) or_return
			entry.value = read_value(d, allocator) or_return
		}
		return
	}
	return
}

/*
encode_value encodes `value` as MessagePack.

Returns:
- data: owned by the caller; free with `delete(data, allocator)`.
- err: an Encode_Error or an allocator error.
*/
encode_value :: proc(value: Value, allocator := context.allocator) -> (data: []byte, err: Error) {
	e: Encoder
	encoder_init(&e, 0, allocator) or_return
	if err = write_value(&e, value); err != nil {
		encoder_destroy(&e)
		return nil, err
	}
	return e.buf[:], nil
}

// write_value appends `value` and everything nested inside it to `e`.
write_value :: proc(e: ^Encoder, value: Value) -> Error {
	switch v in value {
	case nil:
		return write_nil(e)
	case bool:
		return write_bool(e, v)
	case i64:
		return write_int(e, v)
	case u64:
		return write_uint(e, v)
	case f32:
		return write_f32(e, v)
	case f64:
		return write_f64(e, v)
	case string:
		return write_str(e, v)
	case Binary:
		return write_bin(e, cast([]byte)v)
	case Extension:
		return write_ext(e, v.type, v.data)
	case Timestamp:
		return write_timestamp(e, v)
	case Array:
		write_array_header(e, len(v)) or_return
		for item in v {
			write_value(e, item) or_return
		}
	case Map:
		write_map_header(e, len(v)) or_return
		for entry in v {
			write_value(e, entry.key) or_return
			write_value(e, entry.value) or_return
		}
	}
	return nil
}

/*
value_destroy frees everything that `value` owns. Pass the allocator that
created it. Calling it on `nil` or on a scalar does nothing.
*/
value_destroy :: proc(value: Value, allocator := context.allocator) {
	switch v in value {
	case nil, bool, i64, u64, f32, f64, Timestamp:
	case string:
		delete(v, allocator)
	case Binary:
		delete(v, allocator)
	case Extension:
		delete(v.data, allocator)
	case Array:
		for item in v {
			value_destroy(item, allocator)
		}
		delete(v, allocator)
	case Map:
		for entry in v {
			value_destroy(entry.key, allocator)
			value_destroy(entry.value, allocator)
		}
		delete(v, allocator)
	}
}

/*
map_get returns the value of the first entry in `m` whose key is the string
`key`. It doesn't allocate, and the result borrows from `m`.
*/
map_get :: proc(m: Map, key: string) -> (value: Value, ok: bool) {
	for entry in m {
		if k, is_str := entry.key.(string); is_str && k == key {
			return entry.value, true
		}
	}
	return nil, false
}

@(private)
clone_bytes :: proc(b: []byte, allocator := context.allocator) -> (out: []byte, err: mem.Allocator_Error) {
	if len(b) == 0 {
		return nil, nil
	}
	out = make([]byte, len(b), allocator) or_return
	copy(out, b)
	return out, nil
}

/*
value_equal reports whether `a` and `b` hold the same MessagePack data,
comparing containers element by element. An `i64` and a `u64` with the same
numeric value are equal; `f32` and `f64` are compared only with their own kind.
*/
value_equal :: proc(a, b: Value) -> bool {
	switch x in a {
	case nil:
		return b == nil
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case i64:
		#partial switch y in b {
		case i64:
			return x == y
		case u64:
			return x >= 0 && u64(x) == y
		}
		return false
	case u64:
		#partial switch y in b {
		case u64:
			return x == y
		case i64:
			return y >= 0 && u64(y) == x
		}
		return false
	case f32:
		y, ok := b.(f32)
		return ok && x == y
	case f64:
		y, ok := b.(f64)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case Binary:
		y, ok := b.(Binary)
		return ok && string(x) == string(y)
	case Extension:
		y, ok := b.(Extension)
		return ok && x.type == y.type && string(x.data) == string(y.data)
	case Timestamp:
		y, ok := b.(Timestamp)
		return ok && x == y
	case Array:
		y, ok := b.(Array)
		if !ok || len(x) != len(y) {
			return false
		}
		for item, i in x {
			if !value_equal(item, y[i]) {
				return false
			}
		}
		return true
	case Map:
		y, ok := b.(Map)
		if !ok || len(x) != len(y) {
			return false
		}
		for entry, i in x {
			if !value_equal(entry.key, y[i].key) || !value_equal(entry.value, y[i].value) {
				return false
			}
		}
		return true
	}
	return false
}
