// Example stream writes items one at a time with an Encoder and reads them back with a Decoder.
// Run it with `odin run examples/stream`.
package main

import msgpack "../.."
import "core:fmt"
import "core:os"

main :: proc() {
	e: msgpack.Encoder
	if err := msgpack.encoder_init(&e); err != nil {
		fmt.eprintln("encoder_init failed:", err)
		os.exit(1)
	}
	defer msgpack.encoder_destroy(&e)

	if err := write_record(&e); err != nil {
		fmt.eprintln("encode failed:", err)
		os.exit(1)
	}

	d: msgpack.Decoder
	msgpack.decoder_init(&d, msgpack.encoder_bytes(&e))
	if err := read_record(&d); err != nil {
		fmt.eprintln("decode failed:", err)
		os.exit(1)
	}
}

// write_record writes one log record: [timestamp, level, message, payload].
write_record :: proc(e: ^msgpack.Encoder) -> msgpack.Error {
	msgpack.write_array_header(e, 4) or_return
	msgpack.write_timestamp(e, {seconds = 1_700_000_000, nanoseconds = 250}) or_return
	msgpack.write_uint(e, 3) or_return
	msgpack.write_str(e, "disk almost full") or_return
	return msgpack.write_ext(e, 1, {0xca, 0xfe})
}

// read_record reads the record back with the matching typed reads.
read_record :: proc(d: ^msgpack.Decoder) -> msgpack.Error {
	n := msgpack.read_array_header(d) or_return
	if n != 4 {
		return msgpack.Decode_Error.Type_Mismatch
	}
	ts := msgpack.read_timestamp(d) or_return
	level := msgpack.read_uint(d) or_return
	// read_str borrows the input buffer, so it needs no allocation.
	message := msgpack.read_str(d) or_return
	type, payload := msgpack.read_ext(d) or_return
	fmt.printfln("t=%d.%09d level=%d message=%q ext(%d, %x)", ts.seconds, ts.nanoseconds, level, message, type, string(payload))
	return nil
}
