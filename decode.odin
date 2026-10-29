package msgpack

/*
Decoder reads MessagePack items from a byte slice, one at a time.

Set one up with decoder_init. A Decoder never allocates and never copies:
read_str, read_bin and read_ext return slices that borrow the input, so keep
the input alive while you use them. When a read fails, the decoder's position
stays where it was, so you can retry with a different read procedure.

A Decoder is safe to use from one thread at a time.
*/
Decoder :: struct {
	// The whole input.
	data:      []byte,
	// Offset of the next unread byte in `data`.
	pos:       int,
	// Deepest nesting that skip, read_value and unmarshal accept.
	max_depth: int,
	// Current nesting, tracked by skip, read_value and unmarshal.
	depth:     int,
}

/*
decoder_init points `d` at `data`. The decoder borrows `data` and doesn't
free it.

Inputs:
- d: the decoder to set up.
- data: the MessagePack input.
- max_depth: the deepest nesting of arrays, maps and pointers to accept.
*/
decoder_init :: proc(d: ^Decoder, data: []byte, max_depth := DEFAULT_MAX_DEPTH) {
	d^ = Decoder {
		data      = data,
		max_depth = max_depth,
	}
}

// decoder_remaining returns how many input bytes the decoder hasn't read yet.
decoder_remaining :: proc(d: ^Decoder) -> int {
	return len(d.data) - d.pos
}

/*
peek_kind reports the type family of the next item without consuming it.
Fails with `.Unexpected_Eof` at the end of input and `.Invalid_Format` on the
reserved byte 0xc1.
*/
peek_kind :: proc(d: ^Decoder) -> (kind: Kind, err: Error) {
	b := peek_byte(d) or_return
	switch b {
	case 0x00 ..= 0x7f, 0xe0 ..= 0xff, FMT_UINT8 ..= FMT_INT64:
		return .Int, nil
	case 0x80 ..= 0x8f, FMT_MAP16, FMT_MAP32:
		return .Map, nil
	case 0x90 ..= 0x9f, FMT_ARRAY16, FMT_ARRAY32:
		return .Array, nil
	case 0xa0 ..= 0xbf, FMT_STR8 ..= FMT_STR32:
		return .String, nil
	case FMT_NIL:
		return .Nil, nil
	case FMT_FALSE, FMT_TRUE:
		return .Bool, nil
	case FMT_BIN8 ..= FMT_BIN32:
		return .Binary, nil
	case FMT_FLOAT32, FMT_FLOAT64:
		return .Float, nil
	case FMT_EXT8 ..= FMT_EXT32, FMT_FIXEXT1 ..= FMT_FIXEXT16:
		start := d.pos
		type, _ := read_ext_header(d) or_return
		d.pos = start
		return .Timestamp if type == TIMESTAMP_EXT_TYPE else .Extension, nil
	case:
		return .Nil, Decode_Error.Invalid_Format
	}
}

// read_nil consumes a nil item. Fails with `.Type_Mismatch` on anything else.
read_nil :: proc(d: ^Decoder) -> Error {
	b := peek_byte(d) or_return
	if b != FMT_NIL {
		return Decode_Error.Type_Mismatch
	}
	d.pos += 1
	return nil
}

// read_bool consumes a bool item. Fails with `.Type_Mismatch` on anything else.
read_bool :: proc(d: ^Decoder) -> (value: bool, err: Error) {
	switch peek_byte(d) or_return {
	case FMT_TRUE:
		d.pos += 1
		return true, nil
	case FMT_FALSE:
		d.pos += 1
		return false, nil
	}
	return false, Decode_Error.Type_Mismatch
}

/*
read_int consumes an integer item of any width. Fails with `.Integer_Overflow`
when an unsigned value exceeds `max(i64)`, and `.Type_Mismatch` on non-integers.
*/
read_int :: proc(d: ^Decoder) -> (value: i64, err: Error) {
	start := d.pos
	x := read_integer(d) or_return
	if x > i128(max(i64)) {
		d.pos = start
		return 0, Decode_Error.Integer_Overflow
	}
	return i64(x), nil
}

/*
read_uint consumes an integer item of any width. Fails with
`.Integer_Overflow` when the value is negative, and `.Type_Mismatch` on
non-integers.
*/
read_uint :: proc(d: ^Decoder) -> (value: u64, err: Error) {
	start := d.pos
	x := read_integer(d) or_return
	if x < 0 {
		d.pos = start
		return 0, Decode_Error.Integer_Overflow
	}
	return u64(x), nil
}

/*
read_float consumes a float32 or float64 item and widens it to f64. It also
accepts integers, because many encoders write whole numbers that way.
Fails with `.Type_Mismatch` on anything else.
*/
read_float :: proc(d: ^Decoder) -> (value: f64, err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	switch peek_byte(d) or_return {
	case FMT_FLOAT32:
		d.pos += 1
		bits := take_uint(d, 4) or_return
		return f64(transmute(f32)u32(bits)), nil
	case FMT_FLOAT64:
		d.pos += 1
		bits := take_uint(d, 8) or_return
		return transmute(f64)bits, nil
	}
	x := read_integer(d) or_return
	return f64(x), nil
}

/*
read_str consumes a str item. The result borrows the decoder's input; clone
it if it must outlive the input. Fails with `.Type_Mismatch` on non-strings.
*/
read_str :: proc(d: ^Decoder) -> (value: string, err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	n: int
	b := take_byte(d) or_return
	switch b {
	case 0xa0 ..= 0xbf:
		n = int(b & 0x1f)
	case FMT_STR8:
		n = take_len(d, 1) or_return
	case FMT_STR16:
		n = take_len(d, 2) or_return
	case FMT_STR32:
		n = take_len(d, 4) or_return
	case:
		return "", Decode_Error.Type_Mismatch
	}
	bytes := take(d, n) or_return
	return string(bytes), nil
}

/*
read_bin consumes a bin item. The result borrows the decoder's input; clone
it if it must outlive the input. Fails with `.Type_Mismatch` on anything else.
*/
read_bin :: proc(d: ^Decoder) -> (value: []byte, err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	n: int
	switch take_byte(d) or_return {
	case FMT_BIN8:
		n = take_len(d, 1) or_return
	case FMT_BIN16:
		n = take_len(d, 2) or_return
	case FMT_BIN32:
		n = take_len(d, 4) or_return
	case:
		return nil, Decode_Error.Type_Mismatch
	}
	return take(d, n)
}

/*
read_array_header consumes an array header and returns the element count.
Read exactly that many items next. Fails with `.Unexpected_Eof` when the
input is too short to hold the declared count.
*/
read_array_header :: proc(d: ^Decoder) -> (count: int, err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	b := take_byte(d) or_return
	switch b {
	case 0x90 ..= 0x9f:
		count = int(b & 0x0f)
	case FMT_ARRAY16:
		count = take_len(d, 2) or_return
	case FMT_ARRAY32:
		count = take_len(d, 4) or_return
	case:
		return 0, Decode_Error.Type_Mismatch
	}
	// Every item takes at least one byte, so reject impossible counts early.
	if count > decoder_remaining(d) {
		return 0, Decode_Error.Unexpected_Eof
	}
	return count, nil
}

/*
read_map_header consumes a map header and returns the number of key and
value pairs. Read exactly twice that many items next. Fails with
`.Unexpected_Eof` when the input is too short to hold the declared count.
*/
read_map_header :: proc(d: ^Decoder) -> (count: int, err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	b := take_byte(d) or_return
	switch b {
	case 0x80 ..= 0x8f:
		count = int(b & 0x0f)
	case FMT_MAP16:
		count = take_len(d, 2) or_return
	case FMT_MAP32:
		count = take_len(d, 4) or_return
	case:
		return 0, Decode_Error.Type_Mismatch
	}
	if count > decoder_remaining(d) / 2 {
		return 0, Decode_Error.Unexpected_Eof
	}
	return count, nil
}

/*
read_ext consumes an extension item of any type, including the timestamp.
`data` borrows the decoder's input. Fails with `.Type_Mismatch` on anything else.
*/
read_ext :: proc(d: ^Decoder) -> (type: i8, data: []byte, err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	n: int
	type, n = read_ext_header(d) or_return
	data = take(d, n) or_return
	return
}

/*
read_timestamp consumes a timestamp extension in any of its three layouts.
Fails with `.Type_Mismatch` on other items and `.Invalid_Timestamp` on a bad
payload length or nanoseconds of 1e9 or more.
*/
read_timestamp :: proc(d: ^Decoder) -> (ts: Timestamp, err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	type, data := read_ext(d) or_return
	if type != TIMESTAMP_EXT_TYPE {
		return {}, Decode_Error.Type_Mismatch
	}
	return parse_timestamp(data)
}

/*
skip consumes the next item, including everything nested inside it, without
allocating. Fails with `.Max_Depth_Exceeded` past the decoder's `max_depth`.
*/
skip :: proc(d: ^Decoder) -> (err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	enter(d) or_return
	defer d.depth -= 1

	switch peek_kind(d) or_return {
	case .Nil, .Bool:
		d.pos += 1
	case .Int:
		_ = read_integer(d) or_return
	case .Float:
		_ = read_float(d) or_return
	case .String:
		_ = read_str(d) or_return
	case .Binary:
		_ = read_bin(d) or_return
	case .Extension, .Timestamp:
		_, _ = read_ext(d) or_return
	case .Array:
		n := read_array_header(d) or_return
		for _ in 0 ..< n {
			skip(d) or_return
		}
	case .Map:
		n := read_map_header(d) or_return
		for _ in 0 ..< 2 * n {
			skip(d) or_return
		}
	}
	return nil
}

// parse_timestamp decodes the payload of a timestamp extension.
@(private)
parse_timestamp :: proc(data: []byte) -> (ts: Timestamp, err: Error) {
	switch len(data) {
	case 4:
		ts.seconds = i64(load_be(data))
	case 8:
		v := load_be(data)
		ts.nanoseconds = u32(v >> 34)
		ts.seconds = i64(v & 0x3_ffff_ffff)
	case 12:
		ts.nanoseconds = u32(load_be(data[:4]))
		ts.seconds = i64(load_be(data[4:]))
	case:
		return {}, Decode_Error.Invalid_Timestamp
	}
	if ts.nanoseconds >= 1_000_000_000 {
		return {}, Decode_Error.Invalid_Timestamp
	}
	return ts, nil
}

// enter records one more level of nesting and enforces `max_depth`.
@(private)
enter :: proc(d: ^Decoder) -> Error {
	if d.depth >= d.max_depth {
		return Decode_Error.Max_Depth_Exceeded
	}
	d.depth += 1
	return nil
}

// read_integer consumes an integer of any format and widens it to i128.
@(private)
read_integer :: proc(d: ^Decoder) -> (value: i128, err: Error) {
	start := d.pos
	defer if err != nil {
		d.pos = start
	}
	b := take_byte(d) or_return
	switch b {
	case 0x00 ..= 0x7f:
		return i128(b), nil
	case 0xe0 ..= 0xff:
		return i128(i8(b)), nil
	case FMT_UINT8:
		return i128(take_uint(d, 1) or_return), nil
	case FMT_UINT16:
		return i128(take_uint(d, 2) or_return), nil
	case FMT_UINT32:
		return i128(take_uint(d, 4) or_return), nil
	case FMT_UINT64:
		return i128(take_uint(d, 8) or_return), nil
	case FMT_INT8:
		return i128(i8(take_uint(d, 1) or_return)), nil
	case FMT_INT16:
		return i128(i16(take_uint(d, 2) or_return)), nil
	case FMT_INT32:
		return i128(i32(take_uint(d, 4) or_return)), nil
	case FMT_INT64:
		return i128(i64(take_uint(d, 8) or_return)), nil
	}
	return 0, Decode_Error.Type_Mismatch
}

@(private)
read_ext_header :: proc(d: ^Decoder) -> (type: i8, length: int, err: Error) {
	switch take_byte(d) or_return {
	case FMT_FIXEXT1:
		length = 1
	case FMT_FIXEXT2:
		length = 2
	case FMT_FIXEXT4:
		length = 4
	case FMT_FIXEXT8:
		length = 8
	case FMT_FIXEXT16:
		length = 16
	case FMT_EXT8:
		length = take_len(d, 1) or_return
	case FMT_EXT16:
		length = take_len(d, 2) or_return
	case FMT_EXT32:
		length = take_len(d, 4) or_return
	case:
		return 0, 0, Decode_Error.Type_Mismatch
	}
	type = i8(take_byte(d) or_return)
	return type, length, nil
}

@(private)
peek_byte :: proc(d: ^Decoder) -> (b: byte, err: Error) {
	if d.pos >= len(d.data) {
		return 0, Decode_Error.Unexpected_Eof
	}
	return d.data[d.pos], nil
}

@(private)
take_byte :: proc(d: ^Decoder) -> (b: byte, err: Error) {
	b = peek_byte(d) or_return
	d.pos += 1
	return b, nil
}

@(private)
take :: proc(d: ^Decoder, n: int) -> (bytes: []byte, err: Error) {
	if n < 0 || n > len(d.data) - d.pos {
		return nil, Decode_Error.Unexpected_Eof
	}
	bytes = d.data[d.pos:][:n]
	d.pos += n
	return bytes, nil
}

// take_uint reads a big-endian unsigned integer of `size` bytes.
@(private)
take_uint :: proc(d: ^Decoder, size: int) -> (value: u64, err: Error) {
	bytes := take(d, size) or_return
	return load_be(bytes), nil
}

// take_len reads a big-endian length of `size` bytes and checks that it fits in an int.
@(private)
take_len :: proc(d: ^Decoder, size: int) -> (n: int, err: Error) {
	v := take_uint(d, size) or_return
	if v > u64(max(int)) {
		return 0, Decode_Error.Unexpected_Eof
	}
	return int(v), nil
}

@(private)
load_be :: proc(bytes: []byte) -> (value: u64) {
	for b in bytes {
		value = value << 8 | u64(b)
	}
	return
}
