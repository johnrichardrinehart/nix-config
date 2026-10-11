# USB-C / Thunderbolt / MST display experiment plan

The failure path has several independent layers:

1. USB-C cable orientation and monitor Type-C/Thunderbolt negotiation
2. host NHI and monitor USB4 router enumeration
3. DisplayPort tunnel allocation
4. DP AUX/EDID and MST branch discovery
5. i915 link training
6. compositor output configuration
7. physical monitor power/deep-sleep behavior

Do not infer that USB and Ethernet working proves the DP path is healthy. They use
separate tunnels after the common USB4 link is established.

## Capture procedure

After deploying the telemetry module, capture a known-good baseline and every
failure before unplugging the cable:

```console
sudo display-link-debug snapshot good
sudo display-link-debug snapshot failed
sudo display-link-debug diagnose
```

For one deliberately reproduced failure, enable detailed logging first:

```console
sudo display-link-debug dynamic-debug on
sudo display-link-debug trace on
# connect the cable, or suspend and resume
sudo display-link-debug snapshot verbose-failure
sudo display-link-debug trace off
sudo display-link-debug dynamic-debug off
```

Snapshots are stored in `/var/log/display-link-debug`. They include the kernel
journal, DRM connector/EDID state, Thunderbolt topology, PCI runtime/D3cold
state, USB topology, i915 display debugfs data when available, and DDC VCP D6
monitor power state when the monitor answers DDC.

## Fault classification

| Observed state | Most likely failing layer |
| --- | --- |
| No downstream Thunderbolt device and no external DRM connector | cable, monitor deep sleep/input selection, USB-C negotiation, authorization, or host NHI power |
| Monitor Thunderbolt device present, but no external DRM connector | DP tunnel allocation, DP AUX, or i915 hotplug |
| First external connector present, second absent | monitor MST branch/downstream-port wake or MST topology discovery |
| Connector and EDID present, but i915 reports link-training failures | DP signal integrity, cable, bandwidth, or monitor link wake |
| Both connectors present/enabled and no link errors, but no image | compositor modeset or monitor physical power/input state |
| PCI config reads return `0xffff` or logs say `device inaccessible` | host PCI/ACPI D3cold resume path |

## Power-management A/B tests

Change one variable per test and collect at least ten boot-hotplug and ten resume
cycles. The Framework host currently selects its known Thunderbolt root ports,
xHCI function, and NHI functions explicitly.

1. **Host conservative profile**: `preventD3Cold = true` and
   `disableRuntimeSuspend = true`. This is the initial configuration.
2. **Runtime PM only**: keep `preventD3Cold = true`, set
   `disableRuntimeSuspend = false`.
3. **Normal host PM**: set both options false.
4. For each host profile, repeat once with the Dell monitor's OSD deep-sleep/
   energy-saving option disabled and once enabled.
5. Repeat failures with only the 32-inch display, then with the 25-inch MST
   downstream display attached.

Interpretation:

- A strong change between host profiles implicates laptop PCI/runtime power
  management.
- A strong change only with the monitor OSD setting implicates monitor firmware
  wake behavior.
- A failure only with the downstream monitor implicates MST discovery or the
  monitor's downstream DP port.
- No profile effect plus low-level link-training errors points toward cable,
  signal integrity, or kernel DP training.

The recovery service performs bounded Thunderbolt domain rescans. It does not
unbind PCI drivers or remove devices, so a failed state remains inspectable and
the workaround cannot hang the PCI hierarchy. If rescans consistently recover
the link, the next kernel change should place delayed/retried discovery in the
specific layer identified by the snapshots rather than in generic PCI power
transitions.
