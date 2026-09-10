"""Unprivileged reconciliation tests; mount and Btrfs operations are simulated."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'bootprep-reconcile.sh'

def record(path, ident=265, parent='-'):
    return f'ID {ident} gen 27 top level 256 parent_uuid {parent} path {path}\n'

class ReconcileTests(unittest.TestCase):
    def run_case(self, inventory, fstab='UUID=abcd / btrfs subvol=/@ 0 0\n', files=None, active='@'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/'root'
            (root/'etc').mkdir(parents=True)
            (root/'etc/fstab').write_text(fstab)
            for name, value in (files or {}).items():
                dest=root/name; dest.parent.mkdir(parents=True, exist_ok=True); dest.write_text(value)
            (Path(tmp)/'inventory').write_text(inventory)
            script = r'''
set -euo pipefail
source "$HELPER"
mktemp() { local args=(); for arg in "$@"; do args+=("${arg/\/run\//$TMPCASE/}"); done; command mktemp "${args[@]}"; }
btrfs() {
 case "$1 $2" in
 'subvolume list') cat "$TMPCASE/inventory" ;;
 'inspect-internal rootid') echo 265 ;;
 'property get') echo ro=false ;;
 *) return 1 ;;
 esac
}
findmnt() {
 case "$*" in
 '-rn -o TARGET') printf '/\n/home\n' ;;
 '-n -o UUID --mountpoint '*) echo abcd ;;
 '-n -o FSROOT --mountpoint '*) echo / ;;
 '-n -o OPTIONS /') echo 'rw,noatime,compress=zstd:3,subvolid=256,subvol=/@' ;;
 *) return 1 ;;
 esac
}
mount() { echo mount >> "$TMPCASE/calls"; mkdir -p "${@: -1}/@/var/lib/machines"; }
umount() { echo umount >> "$TMPCASE/calls"; }
bp_reconcile_subvolumes "$ROOTCASE" @ "$ACTIVE" abcd /var/lib/bootprep/backups
bp_reconcile_subvolumes "$ROOTCASE" @ "$ACTIVE" abcd /var/lib/bootprep/backups
'''
            env=dict(os.environ, HELPER=str(HELPER), TMPCASE=tmp, ROOTCASE=str(root), ACTIVE=active)
            result=subprocess.run(['bash','-c',script],env=env,text=True,capture_output=True)
            calls=Path(tmp)/'calls'
            return result, (root/'etc/fstab').read_text(), calls.read_text() if calls.exists() else ''

    def test_adopts_and_second_run_is_noop(self):
        result, fstab, calls=self.run_case(record('var/lib/machines'))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(fstab.count(' /var/lib/machines '),1)
        self.assertIn('compress=zstd:3',fstab)
        self.assertEqual(calls,'mount\numount\n')

    def test_destination_files_do_not_block(self):
        result, fstab, _=self.run_case(record('<FS_TREE>/@/var/lib/machines'),files={'var/lib/machines/marker':'snapshot data'},active='@/.snapshots/3/snapshot')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(' /var/lib/machines ',fstab)

    def test_existing_definition_preserved(self):
        original='UUID=abcd / btrfs defaults 0 0\nUUID=abcd /var/lib/machines btrfs subvol=/custom,ro 0 0\n'
        result, fstab, calls=self.run_case(record('var/lib/machines'),original)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(fstab,original); self.assertEqual(calls,'')

    def test_historical_snapshots_excluded(self):
        inventory=record('.snapshots/1/snapshot',270,'snapshot-uuid')+record('.snapshots/1/snapshot/var/lib/machines',271)+record('manual-backup',272,'snapshot-uuid')+record('manual-backup/child',273)
        result, _, calls=self.run_case(inventory)
        self.assertEqual(result.returncode,0,result.stderr); self.assertEqual(calls,'')

    def test_home_boundary(self):
        result, _, calls=self.run_case(record('home/user/nested'))
        self.assertEqual(result.returncode,0,result.stderr); self.assertEqual(calls,'')

    def test_native_mount_definition_requires_review(self):
        result, _, calls=self.run_case(record('var/lib/machines'),files={'etc/systemd/system/var-lib-machines.mount':'[Mount]\n'})
        self.assertNotEqual(result.returncode,0); self.assertIn('requires review',result.stderr); self.assertEqual(calls,'')

    COMPAT = """# systemd legacy compatibility unit
[Unit]
Description=Virtual Machine and Container Storage (Compatibility)
ConditionPathExists=/var/lib/machines.raw
[Mount]
What=/var/lib/machines.raw
Where=/var/lib/machines
Type=btrfs
Options=loop
"""

    def test_unused_vendor_compatibility_unit_allows_adoption(self):
        for directory in ('usr/lib', 'lib'):
            with self.subTest(directory=directory):
                result, fstab, _=self.run_case(record('var/lib/machines'),files={directory+'/systemd/system/var-lib-machines.mount':self.COMPAT})
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn(' /var/lib/machines ',fstab)

    def test_compatibility_image_or_overrides_still_require_review(self):
        for extra in ('var/lib/machines.raw', 'etc/systemd/system/var-lib-machines.mount',
                      'etc/systemd/system/var-lib-machines.mount.d/override.conf',
                      'usr/lib/systemd/system/mount.d/override.conf'):
            with self.subTest(extra=extra):
                files={'usr/lib/systemd/system/var-lib-machines.mount':self.COMPAT, extra:'override'}
                result, fstab, calls=self.run_case(record('var/lib/machines'),files=files)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('requires review',result.stderr)
                self.assertNotIn(' /var/lib/machines ',fstab)
                self.assertEqual(calls,'')

    def test_changed_vendor_mount_is_not_compatibility_exception(self):
        for content in (self.COMPAT.replace('Options=loop','Options=ro'),
                        self.COMPAT.replace('ConditionPathExists=/var/lib/machines.raw','ConditionPathExists=!/var/lib/machines.raw'),
                        self.COMPAT+'What=/different\n'):
            with self.subTest(content=content):
                result, _, calls=self.run_case(record('var/lib/machines'),files={'usr/lib/systemd/system/var-lib-machines.mount':content})
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(calls,'')

    def test_ambiguous_source_refused(self):
        inventory=record('<FS_TREE>/@/var/lib/machines')+record('var/lib/machines',300)
        result, _, calls=self.run_case(inventory,active='@/.snapshots/3/snapshot')
        self.assertNotEqual(result.returncode,0); self.assertIn('Ambiguous',result.stderr); self.assertEqual(calls,'')

    def test_snapshot_store_adopted(self):
        result, fstab, _=self.run_case(record('.snapshots'))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(' /.snapshots btrfs subvol=/@/.snapshots,',fstab)

    def test_already_prefixed_paths_are_not_prefixed_twice(self):
        for active in ('@', '@/.snapshots/3/snapshot'):
            with self.subTest(active=active):
                result, fstab, _=self.run_case(record('@/.snapshots'),active=active)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn(' /.snapshots btrfs subvol=/@/.snapshots,',fstab)
                self.assertNotIn('/@/@/',fstab)

    def test_full_path_inventory_leaves_sibling_subvolumes_out(self):
        inventory=record('@',256)+record('@home',257)+record('@home/user/cache',280)+record('@/.snapshots')
        result, fstab, _=self.run_case(inventory)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(' /.snapshots ',fstab)
        self.assertNotIn('/@/@home',fstab)

    def test_nonstandard_root_path_normalization(self):
        inventory=record('@rootfs/.snapshots')+record('<FS_TREE>/@rootfs/var/lib/machines',266)+record('@rootfs/.snapshots/1/snapshot',270,'snapshot-uuid')
        result=subprocess.run(['bash','-c','source "$1"; bp_subvolume_candidates @rootfs @rootfs', 'test',str(HELPER)],input=inventory,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'@rootfs/.snapshots\t/.snapshots\t265\n@rootfs/var/lib/machines\t/var/lib/machines\t266\n')

    def test_multiple_swap_entries_allowed(self):
        original='UUID=abcd / btrfs defaults 0 0\n/dev/a none swap sw 0 0\n/dev/b none swap sw 0 0\n'
        result, fstab, _=self.run_case('',original)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(fstab,original)

    def test_source_locations(self):
        project=HELPER.parent
        runtime=(project/'bootprep').read_text()
        installer=(project/'bootprep-install.sh').read_text()
        self.assertIn('local helper="/usr/lib/bootprep/bootprep-reconcile.sh"',runtime)
        self.assertNotIn('local_helper',runtime)
        self.assertIn('${SCRIPT_DIR}/bootprep-reconcile.sh',installer)
        self.assertIn('install -Dm644 "$SUBVOLUME_SOURCE" "$SUBVOLUME_DEST"',installer)

    def test_malformed_inventory_refused(self):
        result, _, calls=self.run_case('unexpected metadata\n')
        self.assertNotEqual(result.returncode,0); self.assertEqual(calls,'')

if __name__ == '__main__':
    unittest.main()
