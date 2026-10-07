#!/usr/bin/env python3
"""Read-only Linux graphics/IOMMU inventory, locally or over verified SSH.

Prints JSON only; never binds devices, reads ROM contents, resets hardware,
creates pods, or changes host configuration. This is evidence, not certification.
"""
import argparse
from datetime import datetime, timezone
import json
import platform
from pathlib import Path
import subprocess
import sys


def text(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def target_name(path):
    path = Path(path)
    return path.resolve().name if path.is_symlink() else None


def inventory():
    devices = []
    for device in sorted(Path('/sys/bus/pci/devices').glob('*')):
        pci_class = text(device / 'class')
        if not pci_class or int(pci_class, 16) >> 16 != 0x03:
            continue
        group = device / 'iommu_group'
        drm = device / 'drm'
        mdev = device / 'mdev_supported_types'
        devices.append({
            'pciAddress': device.name,
            'class': pci_class,
            'vendor': text(device / 'vendor'),
            'device': text(device / 'device'),
            'subsystemVendor': text(device / 'subsystem_vendor'),
            'subsystemDevice': text(device / 'subsystem_device'),
            'revision': text(device / 'revision'),
            'driver': target_name(device / 'driver'),
            'iommuGroup': target_name(group),
            'iommuGroupDevices': sorted(p.name for p in (group / 'devices').glob('*')),
            'resetInterfacePresent': (device / 'reset').exists(),
            'resetMethods': text(device / 'reset_method'),
            'bootVga': text(device / 'boot_vga'),
            'romInterfacePresent': (device / 'rom').exists(),
            'drmNodes': sorted(p.name for p in drm.glob('*')),
            'connectedOutputs': {p.name: text(p / 'status')
                                 for card in drm.glob('card[0-9]*')
                                 for p in card.glob('card*-*')},
            'mediatedTypes': sorted(p.name for p in mdev.glob('*')),
            'sriovTotalVfs': text(device / 'sriov_totalvfs'),
            'sriovNumVfs': text(device / 'sriov_numvfs'),
        })
    memory = {}
    for line in (text('/proc/meminfo') or '').splitlines():
        name, value = line.split(':', 1)
        if name in ('MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree'):
            memory[name + 'KiB'] = int(value.split()[0])
    cpus = sorted({line.split(':', 1)[1].strip()
                   for line in (text('/proc/cpuinfo') or '').splitlines()
                   if line.startswith('model name')})
    return {
        'collectedAtUTC': datetime.now(timezone.utc).isoformat(),
        'kernel': platform.release(),
        'architecture': platform.machine(),
        'cpuModels': cpus,
        'memory': memory,
        'loadAverage': (text('/proc/loadavg') or '').split()[:3],
        'graphicsDevices': devices,
        'limitations': [
            'Presence of IOMMU/reset interfaces does not prove safe isolation or repeated reset.',
            'Host i915/render nodes do not prove Windows passthrough, vGPU, VRAM or guest encoding.',
            'ROM presence does not validate UEFI option ROM; no ROM is read or device reset.',
            'Empty mediated/SR-IOV lists mean not exposed now, not a vendor support verdict.',
            'Confirm host console users, all PCI functions, plugin allocation and root/state placement separately.',
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ssh', metavar='USER@HOST', help='Run using host-key-verified, batch SSH')
    args = parser.parse_args()
    if args.ssh:
        if args.ssh.startswith('-') or any(c.isspace() for c in args.ssh):
            parser.error('--ssh must be a single host destination, not SSH options')
        # Send this generic source without creating a remote file or using sudo.
        result = subprocess.run(
            ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
             '-o', 'ConnectTimeout=8', args.ssh, 'python3 -'],
            input=Path(__file__).read_text(), text=True, capture_output=True, timeout=25)
        if result.returncode:
            sys.stderr.write(result.stderr)
            return result.returncode
        report = json.loads(result.stdout)
    else:
        if platform.system() != 'Linux':
            parser.error('local inventory requires Linux')
        report = inventory()
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
