"""Exercise the pgadmin4 target using GNU Make command generation only."""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = Path(os.environ.get("IVORY_CONTAINERS_SOURCE_ROOT", str(ROOT)))


class PgadminBuildahMakeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.make = (
            os.environ.get("MAKE_EXECUTABLE")
            or os.environ.get("GNU_MAKE")
            or shutil.which("gmake")
            or shutil.which("make")
        )
        if not cls.make:
            raise unittest.SkipTest("A real GNU Make executable is required")
        version = subprocess.run(
            [cls.make, "--version"],
            check=True,
            capture_output=True,
            text=True,
        )
        if "GNU Make" not in version.stdout:
            raise unittest.SkipTest("The selected executable is not GNU Make")
        cls.dockerfile = SOURCE_ROOT / "build/pgadmin4/Dockerfile"
        if not cls.dockerfile.is_file():
            raise RuntimeError(
                "Set IVORY_CONTAINERS_SOURCE_ROOT to a complete official checkout; "
                "the real build/pgadmin4/Dockerfile is required, not a placeholder"
            )

    def dry_run(self, builder: str, push: bool, *settings: str) -> list[str]:
        with tempfile.TemporaryDirectory(prefix="pgadmin-make-") as temporary:
            stage = Path(temporary)
            shutil.copyfile(ROOT / "Makefile", stage / "Makefile")
            dockerfile = stage / "build/pgadmin4/Dockerfile"
            dockerfile.parent.mkdir(parents=True)
            shutil.copyfile(self.dockerfile, dockerfile)
            env = os.environ.copy()
            for name in ("MAKEFLAGS", "GNUMAKEFLAGS", "MAKEFILES", "MFLAGS"):
                env.pop(name, None)
            result = subprocess.run(
                [
                    self.make,
                    "--no-print-directory",
                    "-r",
                    "-n",
                    f"CCPROOT={stage.as_posix()}",
                    f"IMGBUILDER={builder}",
                    "IMG_ROOTLESS_BUILD=true",
                    f"IMG_PUSH_TO_DOCKER_DAEMON={str(push).lower()}",
                    *settings,
                    "pgadmin4",
                ],
                cwd=stage,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            # Only normalize Make's printed line continuations; execute none of them.
            output = result.stdout.replace("\\\n", " ")
            return [line.strip() for line in output.splitlines() if line.strip()]

    def assert_build_image(self, commands: list[str], image: str) -> None:
        builds = [
            line for line in commands
            if line.startswith("buildah bud ") or line.startswith("docker build ")
        ]
        self.assertEqual(len(builds), 1, commands)
        self.assertIn(image, re.findall(r"(?:^|\s)-t\s+(\S+)", builds[0]))

    def assert_buildah_handoff(self, commands: list[str], image: str) -> None:
        self.assert_build_image(commands, image)
        pushes = [line for line in commands if "buildah push " in line]
        self.assertEqual(len(pushes), 1, commands)
        self.assertEqual(
            pushes[0],
            f"sudo --preserve-env buildah push {image} docker-daemon:{image}",
        )

    def test_default_buildah_handoff_uses_the_image_just_built(self) -> None:
        self.assert_buildah_handoff(
            self.dry_run("buildah", True),
            "ivorysql/pgadmin:ubi9-9.9-5.1-1",
        )

    def test_overrides_keep_pgadmin_and_database_versions_separate(self) -> None:
        commands = self.dry_run(
            "buildah",
            True,
            "CCP_IMAGE_PREFIX=example/test",
            "CCP_PGADMIN_VERSION=10.2",
            "CCP_IVYO_VERSION=6",
            "CCP_VERSION=7",
            "CCP_IVY_FULLVERSION=99",
        )
        self.assert_buildah_handoff(
            commands, "example/test/pgadmin:ubi9-10.2-6-7"
        )

    def test_buildah_handoff_can_remain_disabled(self) -> None:
        commands = self.dry_run("buildah", False)
        self.assert_build_image(commands, "ivorysql/pgadmin:ubi9-9.9-5.1-1")
        self.assertFalse(any("buildah push " in line for line in commands), commands)

    def test_docker_build_does_not_add_a_buildah_handoff(self) -> None:
        commands = self.dry_run("docker", True)
        self.assert_build_image(commands, "ivorysql/pgadmin:ubi9-9.9-5.1-1")
        self.assertFalse(any("buildah push " in line for line in commands), commands)


if __name__ == "__main__":
    unittest.main()
