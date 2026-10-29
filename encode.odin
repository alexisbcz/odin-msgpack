package msgpack

/*
Encoder appends MessagePack items to a growable byte buffer.

Create one with encoder_init and release it with encoder_destroy. Every write
procedure appends exactly one item, or one container header, and picks the
smallest format that represents the value. An Encoder is safe to use from one
thread at a time.
*/
Encoder :: struct {
	buf: [dynamic]byte,
}

/*
encoder_init prepares `e` for writing. The buffer grows with `allocator`.

Inputs:
- e: the encoder to set up.
- capacity: bytes to reserve up front; 0 reserves nothing.
- allocator: allocates and grows the buffer.

Returns:
- err: an allocator error if the initial reservation fails.
*/
encoder_init :: proc(e: ^Encoder, capacity := 0, allocator := context.allocator) -> (err: Error) {
	e.buf = make([dynamic]byte, 0, capacity, allocator) or_return
	return nil
}

// encoder_destroy frees the encoder's buffer and zeroes the encoder.
encoder_destroy :: proc(e: ^Encoder) {
	delete(e.buf)
	e^ = {}
}

// encoder_reset empties the buffer but keeps its capacity for reuse.
encoder_reset :: proc(e: ^Encoder) {
	clear(&e.buf)
}

/*
encoder_bytes returns the bytes written so far. The slice borrows the
encoder's buffer: it stays valid until the next write, reset or destroy.
*/
encoder_bytes :: proc(e: ^Encoder) -> []byte {
	return e.buf[:]
}

// write_nil appends a MessagePack nil.
write_nil :: proc(e: ^Encoder) -> Error {
	return put(e, FMT_NIL)
}

// write_bool appends `true` or `false`.
write_bool :: proc(e: ^Encoder, value: bool) -> Error {
	return put(e, FMT_TRUE if value else FMT_FALSE)
}

/*
write_int appends a signed integer in the smallest format that holds it.
Non-negative values use the unsigned formats, as the specification recommends.
*/
write_int :: proc(e: ^Encoder, value: i64) -> Error {
	switch {
	case value >= 0:
		return write_uint(e, u64(value))
	case value >= -32:
		return put(e, byte(i8(value)))
	case value >= i64(min(i8)):
		return put(e, FMT_INT8, byte(i8(value)))
	case value >= i64(min(i16)):
		return put_be(e, FMT_INT16, u64(u16(i16(value))), 2)
	case value >= i64(min(i32)):
		return put_be(e, FMT_INT32, u64(u32(i32(value))), 4)
	case:
		return put_be(e, FMT_INT64, u64(value), 8)
	}
}

// write_uint appends an unsigned integer in the smallest format that holds it.
write_uint :: proc(e: ^Encoder, value: u64) -> Error {
	switch {
	case value <= 0x7f:
		return put(e, byte(value))
	case value <= u64(max(u8)):
		return put(e, FMT_UINT8, byte(value))
	case value <= u64(max(u16)):
		return put_be(e, FMT_UINT16, value, 2)
	case value <= u64(max(u32)):
		return put_be(e, FMT_UINT32, value, 4)
	case:
		return put_be(e, FMT_UINT64, value, 8)
	}
}

// write_f32 appends a float32.
write_f32 :: proc(e: ^Encoder, value: f32) -> Error {
	return put_be(e, FMT_FLOAT32, u64(transmute(u32)value), 4)
}

// write_f64 appends a float64.
write_f64 :: proc(e: ^Encoder, value: f64) -> Error {
	return put_be(e, FMT_FLOAT64, transmute(u64)value, 8)
}

/*
write_str appends a str item. MessagePack expects UTF-8 text; the encoder
doesn't check it. Fails with `.Invalid_Length` past 2^32 - 1 bytes.
*/
write_str :: proc(e: ^Encoder, value: string) -> Error {
	n := len(value)
	switch {
	case n <= 31:
		put(e, byte(FMT_FIXSTR | n)) or_return
	case n <= int(max(u8)):
		put(e, FMT_STR8, byte(n)) or_return
	case n <= int(max(u16)):
		put_be(e, FMT_STR16, u64(n), 2) or_return
	case u64(n) <= MAX_LENGTH:
		put_be(e, FMT_STR32, u64(n), 4) or_return
	case:
		return Encode_Error.Invalid_Length
	}
	return put_bytes(e, transmute([]byte)value)
}

// write_bin appends a bin item. Fails with `.Invalid_Length` past 2^32 - 1 bytes.
write_bin :: proc(e: ^Encoder, value: []byte) -> Error {
	n := len(value)
	switch {
	case n <= int(max(u8)):
		put(e, FMT_BIN8, byte(n)) or_return
	case n <= int(max(u16)):
		put_be(e, FMT_BIN16, u64(n), 2) or_return
	case u64(n) <= MAX_LENGTH:
		put_be(e, FMT_BIN32, u64(n), 4) or_return
	case:
		return Encode_Error.Invalid_Length
	}
	return put_bytes(e, value)
}

/*
write_array_header starts an array of `count` items. Write exactly `count`
items after it. Fails with `.Invalid_Length` when `count` is negative or too large.
*/
write_array_header :: proc(e: ^Encoder, count: int) -> Error {
	switch {
	case count < 0:
		return Encode_Error.Invalid_Length
	case count <= 15:
		return put(e, byte(FMT_FIXARRAY | count))
	case count <= int(max(u16)):
		return put_be(e, FMT_ARRAY16, u64(count), 2)
	case u64(count) <= MAX_LENGTH:
		return put_be(e, FMT_ARRAY32, u64(count), 4)
	case:
		return Encode_Error.Invalid_Length
	}
}

/*
write_map_header starts a map of `count` key and value pairs. Write exactly
`2 * count` items after it, alternating keys and values. Fails with
`.Invalid_Length` when `count` is negative or too large.
*/
write_map_header :: proc(e: ^Encoder, count: int) -> Error {
	switch {
	case count < 0:
		return Encode_Error.Invalid_Length
	case count <= 15:
		return put(e, byte(FMT_FIXMAP | count))
	case count <= int(max(u16)):
		return put_be(e, FMT_MAP16, u64(count), 2)
	case u64(count) <= MAX_LENGTH:
		return put_be(e, FMT_MAP32, u64(count), 4)
	case:
		return Encode_Error.Invalid_Length
	}
}

/*
write_ext appends an extension item with type code `type` and payload `data`.
Payloads of 1, 2, 4, 8 and 16 bytes use the compact fixext formats.
*/
write_ext :: proc(e: ^Encoder, type: i8, data: []byte) -> Error {
	n := len(data)
	switch n {
	case 1:
		put(e, FMT_FIXEXT1, byte(type)) or_return
	case 2:
		put(e, FMT_FIXEXT2, byte(type)) or_return
	case 4:
		put(e, FMT_FIXEXT4, byte(type)) or_return
	case 8:
		put(e, FMT_FIXEXT8, byte(type)) or_return
	case 16:
		put(e, FMT_FIXEXT16, byte(type)) or_return
	case:
		switch {
		case n <= int(max(u8)):
			put(e, FMT_EXT8, byte(n), byte(type)) or_return
		case n <= int(max(u16)):
			put_be(e, FMT_EXT16, u64(n), 2) or_return
			put(e, byte(type)) or_return
		case u64(n) <= MAX_LENGTH:
			put_be(e, FMT_EXT32, u64(n), 4) or_return
			put(e, byte(type)) or_return
		case:
			return Encode_Error.Invalid_Length
		}
	}
	return put_bytes(e, data)
}

/*
write_timestamp appends a timestamp extension (type -1) in the smallest of
the three layouts the specification defines: 32, 64 or 96 bits.
Fails with `.Bad_Timestamp` when `ts.nanoseconds >= 1e9`.
*/
write_timestamp :: proc(e: ^Encoder, ts: Timestamp) -> Error {
	if ts.nanoseconds >= 1_000_000_000 {
		return Encode_Error.Bad_Timestamp
	}
	payload: [12]byte
	if ts.seconds >= 0 && ts.seconds >> 34 == 0 {
		if ts.nanoseconds == 0 && ts.seconds <= i64(max(u32)) {
			store_be(payload[:4], u64(ts.seconds))
			return write_ext(e, TIMESTAMP_EXT_TYPE, payload[:4])
		}
		store_be(payload[:8], u64(ts.nanoseconds) << 34 | u64(ts.seconds))
		return write_ext(e, TIMESTAMP_EXT_TYPE, payload[:8])
	}
	store_be(payload[:4], u64(ts.nanoseconds))
	store_be(payload[4:], u64(ts.seconds))
	return write_ext(e, TIMESTAMP_EXT_TYPE, payload[:])
}

@(private)
put :: proc(e: ^Encoder, bytes: ..byte) -> Error {
	return put_bytes(e, bytes)
}

@(private)
put_bytes :: proc(e: ^Encoder, bytes: []byte) -> Error {
	if len(bytes) == 0 {
		return nil
	}
	_, err := append(&e.buf, ..bytes)
	return err
}

// put_be appends a format byte followed by the low `size` bytes of `value`, big-endian.
@(private)
put_be :: proc(e: ^Encoder, format: byte, value: u64, size: int) -> Error {
	tmp: [9]byte
	tmp[0] = format
	store_be(tmp[1:][:size], value)
	return put_bytes(e, tmp[:1 + size])
}

@(private)
store_be :: proc(dst: []byte, value: u64) {
	v := value
	for i := len(dst) - 1; i >= 0; i -= 1 {
		dst[i] = byte(v)
		v >>= 8
	}
}
