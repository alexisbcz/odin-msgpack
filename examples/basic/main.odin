// Example basic marshals a struct, decodes it back and inspects it as a dynamic Value.
// Run it with `odin run examples/basic`.
package main

import msgpack "../.."
import "core:fmt"
import "core:os"

Player :: struct {
	name:     string,
	level:    int,
	tags:     []string,
	password: string `msgpack:"-"`,
	guild:    string `msgpack:"guild,omitempty"`,
}

main :: proc() {
	hero := Player {
		name     = "Ada",
		level    = 7,
		tags     = {"mage", "healer"},
		password = "never encoded",
	}

	data, err := msgpack.marshal(hero)
	if err != nil {
		fmt.eprintln("marshal failed:", err)
		os.exit(1)
	}
	defer delete(data)
	fmt.printfln("encoded %d bytes: %02x", len(data), string(data))

	back: Player
	if err = msgpack.unmarshal(data, &back); err != nil {
		fmt.eprintln("unmarshal failed:", err)
		os.exit(1)
	}
	defer msgpack.destroy(&back)
	fmt.printfln("decoded: %s, level %d, tags %v", back.name, back.level, back.tags)

	doc, derr := msgpack.decode_value(data)
	if derr != nil {
		fmt.eprintln("decode_value failed:", derr)
		os.exit(1)
	}
	defer msgpack.value_destroy(doc)
	if m, ok := doc.(msgpack.Map); ok {
		for entry in m {
			fmt.printfln("  %v = %v", entry.key, entry.value)
		}
	}
}
