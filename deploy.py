import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

DEVICE_SSH_PORT = "2222"
DEVICE_SSH_IP = "localhost"
LOCAL_LDID2_PATH = "/opt/homebrew/bin/ldid2"


@dataclass
class BinaryInstallInformation:
    # The on-device path to copy the binary to
    on_device_path: str
    # An entitlements file to sign the local binary with before copying to the device.
    # If no file is specified, the binary will be signed without explicit entitlements
    entitlements_file: Optional[str] = None


BINARY_DEPLOY_INFO = {
    "objfind": BinaryInstallInformation("/var/jb/usr/bin/objfind", "entitlements.xml"),
}


def run_command_on_device(command: str) -> bytes:
    return subprocess.check_output(
        f'ssh -oStricthostkeychecking=no -oUserknownhostsfile=/dev/null -p {DEVICE_SSH_PORT} root@{DEVICE_SSH_IP} "{command}"',
        shell=True,
    )


def copy_file_to_device(local: str, remote: str) -> None:
    subprocess.check_output(
        f'scp -O -oStricthostkeychecking=no -oUserknownhostsfile=/dev/null -P {DEVICE_SSH_PORT} "{local}" root@{DEVICE_SSH_IP}:"{remote}"',
        shell=True,
    )


def deploy_to_device(local_path: Path, binary_deploy_info: BinaryInstallInformation) -> None:
    # Sign the local binary
    if not Path(LOCAL_LDID2_PATH).exists():
        raise Exception(f"Ldid2 path does not exist locally! {LOCAL_LDID2_PATH}")

    ldid_cmd_args = [LOCAL_LDID2_PATH]
    if binary_deploy_info.entitlements_file:
        ldid_cmd_args.append(f"-S{binary_deploy_info.entitlements_file}")
    else:
        ldid_cmd_args.append("-S")
    ldid_cmd_args.append(local_path.as_posix())
    print(ldid_cmd_args)
#    print(subprocess.check_output(ldid_cmd_args))

    # Delete existing binary on-device if it exists
    try:
        run_command_on_device(f"/var/jb/usr/bin/rm {binary_deploy_info.on_device_path}")
    except:
        print(f"failed to delete on-device binary {binary_deploy_info.on_device_path}")
        pass

    # Ensure the target install directory exists on-device
    try:
        on_device_destination_parent_dir = Path(binary_deploy_info.on_device_path).parent
        run_command_on_device(f"mkdir -p {on_device_destination_parent_dir.as_posix()}")
    except:
        # Dir already exists?
        pass

    # Copy local signed binary to device
    try:
        copy_file_to_device(local_path, binary_deploy_info.on_device_path)
    except Exception as e:
        raise Exception(f"Failed to copy {binary_deploy_info.on_device_path} to device with error: {e}")
    
    try:
        copy_file_to_device(binary_deploy_info.entitlements_file, "/tmp/entitlements.xml")
    except Exception as e:
        print(f"Failed to copy entitlements file to device with error: {e}")
        pass

    run_command_on_device(f"/var/jb/usr/bin/ldid -S/tmp/entitlements.xml {binary_deploy_info.on_device_path}")


if __name__ == "__main__":
    print("deploying binaries device")

    if "BUILT_PRODUCTS_DIR" not in os.environ:
        raise Exception("BUILT_PRODUCTS_DIR not found")

    BUILT_PRODUCTS_DIR = Path(os.environ["BUILT_PRODUCTS_DIR"])
    if not BUILT_PRODUCTS_DIR.exists():
        raise Exception("BUILT_PRODUCTS_DIR var exists but directory does not")

    for framework_path in BUILT_PRODUCTS_DIR.glob("*.framework"):
        fw_binary_path = framework_path / framework_path.stem
        if not fw_binary_path.exists():
            raise Exception(f"file does not exist: {fw_binary_path}")

        if framework_path.stem not in BINARY_DEPLOY_INFO:
            continue

        binary_deploy_info = BINARY_DEPLOY_INFO[framework_path.stem]
        deploy_to_device(fw_binary_path, binary_deploy_info)
