from __future__ import annotations

import shutil
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / "export" / "work" / "issue-1"


def copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def convert_png(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source) as image:
        image.save(destination, format="PNG", optimize=True)


def crop_crystal(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source) as image:
        width, height = image.size
        # Remove the report header/footer while retaining the CFD model and scale.
        cropped = image.crop((0, round(height * 0.105), width, round(height * 0.955)))
        cropped.save(destination, format="PNG", optimize=True)


def main() -> None:
    crop_crystal(
        WORK / "crystal-final.png",
        ROOT / "portfolio" / "crystal-ship" / "assets" / "facade-cfd.png",
    )
    copy(
        WORK / "lakhta-final.png",
        ROOT / "portfolio" / "lakhta-center" / "assets" / "technical-sheet.png",
    )
    copy(
        WORK / "3d-plan-final.png",
        ROOT / "portfolio" / "3d-printing-shop" / "assets" / "ventilation-plan.png",
    )
    copy(
        WORK / "3d-axon-final.png",
        ROOT / "portfolio" / "3d-printing-shop" / "assets" / "ventilation-axonometry.png",
    )
    copy(
        WORK / "shmit-plan-final.png",
        ROOT / "portfolio" / "other-projects" / "assets" / "shmitovsky-ventilation-plan.png",
    )
    copy(
        WORK / "shmit-axon-final.png",
        ROOT / "portfolio" / "other-projects" / "assets" / "shmitovsky-vrf-axonometry.png",
    )

    extracted = WORK / "extracted"
    for source_name, destination in {
        "jk-ice_full.png": ROOT / "portfolio" / "other-projects" / "assets" / "ice-bim-overview.png",
        "jk-ice_section.png": ROOT / "portfolio" / "other-projects" / "assets" / "ice-bim-section.png",
        "vk_k3_full.png": ROOT / "portfolio" / "other-projects" / "assets" / "kingisepp-bim-overview.png",
        "vk_k3_pump.png": ROOT / "portfolio" / "other-projects" / "assets" / "kingisepp-pump-room.png",
        "jk-ice_hap-wrapper.png": ROOT / "portfolio" / "developments" / "hap-wrapper" / "assets" / "workflow.png",
    }.items():
        copy(extracted / source_name, destination)

    convert_png(
        Path(r"C:\Repository\Tools\WorkflowPanel\_dev\verification\issue-3\expanded-150-percent.jpg"),
        ROOT / "portfolio" / "developments" / "workflowpanel" / "assets" / "main-window.png",
    )
    copy(
        Path(r"C:\Repository\Tools\WorkflowPanel\_dev\screenshots\issue-8-github.png"),
        ROOT / "portfolio" / "developments" / "workflowpanel" / "assets" / "profile-or-log.png",
    )


if __name__ == "__main__":
    main()
