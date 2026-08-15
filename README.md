<div align="center">

# OpenMoHAA AppImage 🎮🐧

[![Latest Release](https://img.shields.io/github/v/release/<OWNER>/<REPO>)](https://github.com/<OWNER>/<REPO>/releases/latest)
[![CI Build](https://github.com/<OWNER>/<REPO>/actions/workflows/appimage.yml/badge.svg)](https://github.com/<OWNER>/<REPO>/actions/workflows/appimage.yml)
[![Upstream](https://img.shields.io/badge/upstream-openmoh%2Fopenmohaa-blue)](https://github.com/openmoh/openmohaa)

</div>

---

AppImage portable de [OpenMoHAA](https://github.com/openmoh/openmohaa) construido con la metodología
[Anylinux-AppImages](https://github.com/pkgforge-dev/Anylinux-AppImages). Empaqueta todo
(libc, ld-linux, SDL2, OpenGL, audio, X11, Wayland) y funciona en cualquier Linux.

## 📥 Descarga

```bash
wget https://github.com/<OWNER>/<REPO>/releases/latest/download/openmohaa-x86_64.AppImage
chmod +x openmohaa-x86_64.AppImage
```

## 🎮 Uso

El AppImage detecta automáticamente los assets en una carpeta `main/` junto al `.AppImage`:

```
~/games/openmohaa/
├── openmohaa-x86_64.AppImage
└── main/
    ├── Pak0.pk3      ← assets originales de MoHAA
    ├── Pak1.pk3
    └── ...
```

```bash
cd ~/games/openmohaa
./openmohaa-x86_64.AppImage                    # Cliente
./openmohaa-x86_64.AppImage omohaaded +quit    # Servidor dedicado
```

Los archivos `.pk3` se obtienen de una copia original de Medal of Honor: Allied Assault.

## 🔧 Características

- **Portable**: detecta assets junto al AppImage (no en rutas fijas del home)
- **Auto-seed**: crea `main/cgame.so` y `main/game.so` automáticamente
- **Universal**: funciona en glibc antiguo, musl (Alpine), NixOS
- **Sin FUSE**: cae a extract-and-run si FUSE no está disponible
- **Todos los deps bundlados**: libc, ld-linux, SDL2, OpenGL, ALSA, PulseAudio, X11, Wayland

## 🔄 CI/CD

- **`appimage.yml`**: build manual o automático (workflow_dispatch, repository_dispatch)
- **`check-updates.yml`**: cron diario que abre un Issue si hay nueva versión upstream

Setear variable `AUTO_BUILD=1` en el repo para auto-trigger del build cuando se detecten updates.

## 📜 Licencia

OpenMoHAA se distribuye bajo su propia licencia (ver [upstream](https://github.com/openmoh/openmohaa)).
