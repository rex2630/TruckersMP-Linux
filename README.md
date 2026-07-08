<div align="center">

<img src="https://truckersmp.com/assets/img/truckersmp-logo-sm.png" width="369" height="80"/>

</div>

## A Bash and Python script packaged as an AppImage to automate the installation and configuration of TruckersMP  on Linux.

## Features

- Automatic [TLM](https://github.com/3ventic/tlm) installation
- Automatic UMU-Proton installation if Proton 10 or higher is not detected
- Automatic UMU-Launcher installation
  

## Requirements

### System Dependencies
- UMU-Proton-10.0-4 or higher (Installed automatically)
- curl
- chmod
- mkdir
- awk
- grep
- find
- sed
- tr
- tar

### Supported Games
- Euro Truck Simulator 2
- American Truck Simulator

## Installation

Run the AppImage installer provided in the [releases](https://github.com/rex2630/TruckersMP-Linux/releases) section.

## Troubleshooting

Common issues and solutions:
- If the installer doesn't start, please install all required dependencies.

For further troubleshooting, please run the installer from the terminal and provide the output.

## Uninstallation

To uninstall TruckersMP:
1. Uninstall TruckersMP Launcher using Protontricks.
2. Delete the desktop entry from `~/.local/share/applications/wine/Programs/TruckersMP/`.

## Development

To build the AppImage installer, run the following commands:
```bash
git clone https://github.com/rs189/TruckersMP-Linux.git
cd TruckersMP-Linux
./package_appimage.sh
```

# Licence

This project is licensed under the MIT licence.
