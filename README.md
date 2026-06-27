Cloning the Project
This repository uses Git LFS to store textures and other large binary assets. You must install Git LFS before cloning, or you'll only get small placeholder files instead of the actual textures.
1. Install Git LFS (one time per machine):

Windows / macOS: download from git-lfs.com, or use a package manager (brew install git-lfs, winget install GitHub.GitLFS)
Linux: sudo apt install git-lfs (or your distro's equivalent)

Then run once:
git lfs install
2. Clone the repo as normal:
git clone https://github.com/Francesco-Gamba/HDRP_Shaders_Samples.git
LFS files download automatically during the clone.

If you already cloned without LFS installed, you don't need to re-clone. Just install LFS (steps above) and run this inside the project folder:
git lfs pull
This replaces the placeholder files with the real assets.
