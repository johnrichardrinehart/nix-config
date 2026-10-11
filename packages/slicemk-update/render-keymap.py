import json
from pathlib import Path
import sys


config = json.loads(Path(sys.argv[1]).read_text())
layer_names = {layer["Name"] for layer in config["Layers"]}
for index, layer in enumerate(config["Layers"]):
    print(f"#define LAYER_{layer['Name'].upper()} {index}")
print("#include <behaviors.dtsi>")
for header in ("bt", "keys", "outputs", "pointing", "rgb"):
    print(f"#include <dt-bindings/zmk/{header}.h>")
print(config["Custom"])
if config["Shield"] == "slicemk_ergodox_leftcentral":
    # Keep the hardware power button local to this half.
    print(
        '/ { behaviors { local_off: local_off { compatible = "zmk,behavior-soft-off"; #binding-cells = <0>; }; }; };'
    )
    button = "&local_off"
else:
    button = "&bootloader"
print('/ { keymap { compatible = "zmk,keymap";')
for index, layer in enumerate(config["Layers"]):
    print(f"layer_{index} {{ bindings = <")
    print(button)
    for key in layer["Keys"]:
        behavior = "" if key["Behavior"] == "$custom" else key["Behavior"]
        args = [
            f"LAYER_{arg.upper()}" if arg in layer_names else arg for arg in key["Args"]
        ]
        print(" ".join([behavior, *args]).strip())
    print(">; };")
print("}; };")
