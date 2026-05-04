# 🎮 ONScripterYuri k3s Launcher

[![ONScripter Yuri](https://img.shields.io/github/v/release/YuriSizuku/OnscripterYuri?color=green&label=onsyuri&logo=4chan&style=flat-square)](https://github.com/YuriSizuku/OnscripterYuri#3-web)
![WSL support](https://img.shields.io/badge/platform-WSL2-blue?logo=ubuntu&logoColor=white)
[![k3s](https://img.shields.io/badge/k3s-lightweight%20kubernetes-orange?logo=kubernetes&logoColor=white)](https://k3s.io/)
![shell scripting](https://img.shields.io/badge/shell-bash-black?logo=gnubash&logoColor=white)
![license: GPLv3](https://img.shields.io/badge/license-GPLv3-lightgrey?logo=gplv3&logoColor=white)

## 📖 What Is This?

> **One-script deployment of a locally-hosted 
[ONScripterYuri](https://github.com/YuriSizuku/OnscripterYuri#3-web)
web game server using Kubernetes ([k3s](https://k3s.io/)) — running entirely on your local machine (or maybe your server?)**

---

## ⚠️ Platform Notice

> **This tool has only been tested on WSL2 (Windows Subsystem for Linux 2).**
>
> While the script includes scaffolding for **macOS** (via [k3d](https://k3d.io/)), **Raspberry Pi**, and **generic Linux**, these paths are **untested and may require manual adjustments**. Use them at your own risk.

---

## 🧰 Requirements

### All Platforms
| Requirement | Notes |
|---|---|
| `envsubst` | Part of `gettext`; needed to patch manifests |
| ONScripter Yuri | [![](https://img.shields.io/badge/ONScripterYuri-Web-blue)](https://github.com/YuriSizuku/OnscripterYuri#3-web) |
| port `80` | Change in k3s [manifest](/k3s-manifests.yaml), nginx [config](/nginx.conf) if needed |

### WSL2 (Tested)
| Requirement | Notes |
|---|---|
| WSL2 with a Debian/Ubuntu distro | Ubuntu 24.04 LTS tested |

### macOS (⚠️ Untested)
| Requirement | Notes |
|---|---|
| `docker` | k3d runs k3s inside Docker |
| `Homebrew` | Used to install k3d |

---

## 🚀 Usage

```bash
# Clone this repo and place your game files at the expected root path (see below)
$ git clone <this-repo>
$ cd <this-repo>

# Full install: installs k3s and deploys the game
$ ./onsyuri-k3s.sh install

# With a custom root path and game title
$ ./onsyuri-k3s.sh install -i /path/to/onsyuri/web--game mygame

# Re-deploy manifests only (no k3s reinstall)
$ ./onsyuri-k3s.sh deploy
$ ./onsyuri-k3s.sh deploy -i /path/to/onsyuri/web --game mygame
```

### All Commands

| Command | Description |
|---|---|
| `install [-i PATH] [--game TITLE]` | Install k3s/k3d + deploy everything |
| `deploy [-i PATH] [--game TITLE]` | Re-apply manifests only (clean + redeploy) |
| `status` | Show pod and service status + access URLs |
| `restart` | Restart the pod (re-runs init container, regenerates `index.json`) |
| `logs` | Tail live nginx logs |
| `clean` | Delete the deployment, PVC, and PV |
| `debug` | Open an interactive shell inside the running pod |
| `uninstall` | Fully remove k3s/k3d and all cluster data |

### Options

| OPTION | Applies To | Description |
|---|---|---|
| `-i`, `--root-path PATH` | `install`, `deploy` | Override the default OnscripterYuri Path  |
| `--game GAMETITLE` | `install`, `deploy` | Specify which game subdirectory to use |


| OS | Default PATH |
|---|---|
| win | `~/Saved Games/onsyuri_web` |
| mac | `~/Games/onsyuri_web` |
| rpi | `~/onsyuri_web` |
| other | `/opt/onsyuri_web` |

---

## 📁 Expected Directory Layout

```
<ROOT_PATH>/                   # e.g. C:\Users\<yourusername>\Saved Games\onsyuri_web  (WSL2 default)
├── onsyuri_index.py           # index generator script
├── onsyuri.html / .js / .wasm # onscripter web index and engine
└── <GAME_SUBDIR>/             # e.g. "onsyuri2" — auto-detected or set via --game to 
    └── ...                    # game data files

<SCRIPT_DIR>/                  # wherever you cloned this repo
├── onsyuri-k3s.sh             # this script
├── k3s-manifests.yaml         # Kubernetes manifest template (required)
└── nginx.conf                 # nginx configuration (required)
```

---

## 🌐 Accessing the Game

After a successful deploy, the game is available at:

| URL | Notes |
|---|---|
| `http://localhost/` | Local access from the same machine |
| `http://<your-LAN-IP>/` | Access from other devices on your network |
| wsl: `http://<virtual-LAN-IP>` | Access from local if you didn't forward your connection and port |

Run `./onsyuri-k3s.sh status` at any time to see the current URLs.

---

## 🐛 Troubleshooting

**Pod stuck in `Init` or `Pending`?**
```bash
$ kubectl logs -n onsyuri -l app=onsyuri -c index-generator
$ kubectl describe pod -n onsyuri -l app=onsyuri
```

**Need a shell inside the pod?**
```bash
$ ./onsyuri-k3s.sh debug
```

**Game files updated, need to regenerate the index?**
```bash
$ ./onsyuri-k3s.sh restart
```

**Start fresh?**
```bash
$ ./onsyuri-k3s.sh deploy
```

---

## 🏗️ How It Works

### Deployment Flow (`install` / `deploy`)

1. **Platform detection** — inspects `/proc/version`, `/proc/cpuinfo`, or `uname -s`
2. **Path resolution** — uses the platform default or your `-i` override; auto-detects the game subdirectory
3. **Path validation** — checks that all required files exist before touching the cluster
4. **k3s install** (install only) — runs the official `curl | sh` installer; copies kubeconfig to `~/.kube/config`
5. **Manifest patching** — renders `k3s-manifests.yaml` into a temp file with real paths substituted
6. **Apply** — `kubectl apply -f` the rendered manifest (Namespace, PV, PVC, Deployment, Service, Ingress)
7. **Health wait** — polls until the pod is `Ready` (up to 3 minutes; init container may pull images)
8. **Status** — prints pod state and access URLs

### Architecture Overview

```
  Your Browser
      │  http://localhost/ or http://<LAN-IP>/
      ▼
  k3s Traefik Ingress (port 80)
      │
      ▼
  Kubernetes Service (ClusterIP)
      │
      ▼
  nginx Pod  ◄──── hostPath PersistentVolume ────► Your local game files
      │                                              (mounted read-only)
      │
  Init Container (runs first)
      └── python3 onsyuri_index.py → generates index.json
```

### Tech Stack

| Layer | Technology | Role |
|---|---|---|
| **Orchestration** | k3s | Lightweight single-node Kubernetes — runs as a `systemd` service |
| **Ingress** | k3s built-in Traefik | Routes external HTTP traffic into the cluster on port 80 |
| **Web Server** | nginx (Alpine) | Serves static game files; config injected |
| **Init Container** | Python 3 | Runs `onsyuri_index.py` on every pod start to regenerate `index.json` |
| **Storage** | Kubernetes `hostPath` PV/PVC | Mounts your local game directory directly into the pod — no copying |
| **Manifest Templating** | `envsubst` | Substitutes `${ROOT_PATH}`, `${GAME_SUBDIR}`, `${SCRIPT_DIR}` into the YAML before applying |

---

## 🤝 Contributing

Platform-specific fixes and test reports for macOS, Raspberry Pi, and native Linux are very welcome. Please open an PR describing your environment.

---

## 📄 License

[GPLv3](/LICENSE)