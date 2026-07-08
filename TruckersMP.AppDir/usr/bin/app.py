import sys
import os
import subprocess
from PyQt5.QtCore import Qt, QThread, pyqtSignal
from PyQt5.QtWidgets import QApplication, QMainWindow, QVBoxLayout, QPushButton, QPlainTextEdit, QProgressBar, QWidget, QMessageBox
import re

class InstallerThread(QThread):
    log_signal = pyqtSignal(str)
    progress_signal = pyqtSignal(int)
    error_signal = pyqtSignal(str)
    finished_signal = pyqtSignal(bool, str)

    def run(self):
        appdir = os.getenv("APPDIR", ".")
        script_path = os.path.join(appdir, "usr", "bin", "install_truckersmp.sh")

        if not os.path.isfile(script_path):
            self.error_signal.emit(f"Installer script was not found: {script_path}")
            self.finished_signal.emit(False, "Installer script was not found.")
            return

        if not os.access(script_path, os.X_OK):
            self.error_signal.emit(f"Installer script is not executable: {script_path}")
            self.finished_signal.emit(False, "Installer script is not executable.")
            return

        try:
            process = subprocess.Popen(
                [script_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
        except Exception as e:
            self.error_signal.emit(f"Failed to start installer script: {e}")
            self.finished_signal.emit(False, f"Failed to start installer script: {e}")
            return

        last_error = None

        for raw_line in process.stdout:
            line = raw_line.strip()
            if not line:
                continue

            progress_match = re.match(r"^PROGRESS:(\d+)$", line)
            error_match = re.match(r"^ERROR:(.*)$", line)
            warn_match = re.match(r"^WARN:(.*)$", line)
            info_match = re.match(r"^INFO:(.*)$", line)
            done_match = re.match(r"^DONE:(.*)$", line)

            if progress_match:
                progress = max(0, min(100, int(progress_match.group(1))))
                self.progress_signal.emit(progress)
                continue

            if error_match:
                msg = error_match.group(1).strip()
                last_error = msg
                self.log_signal.emit(f"[ERROR] {msg}")
                self.error_signal.emit(msg)
                continue

            if warn_match:
                msg = warn_match.group(1).strip()
                self.log_signal.emit(f"[WARN] {msg}")
                continue

            if info_match:
                msg = info_match.group(1).strip()
                self.log_signal.emit(msg)
                continue

            if done_match:
                msg = done_match.group(1).strip()
                self.log_signal.emit(msg)
                continue

            self.log_signal.emit(line)

        process.wait()

        if process.returncode == 0:
            self.progress_signal.emit(100)
            self.finished_signal.emit(
                True,
                "Installation completed successfully.\n\n"
                "Next steps:\n"
                "1. Restart Steam.\n"
                "2. Open ETS2/ATS properties.\n"
                "3. Enable 'Force the use of a specific Steam Play compatibility tool'.\n"
                "4. Select 'TruckersMP [TLM]'.\n"
                "5. Launch the game."
            )
        else:
            message = last_error or f"Installation failed with exit code {process.returncode}."
            self.finished_signal.emit(False, message)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("TruckersMP Installer")
        self.setGeometry(100, 100, 760, 480)

        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        layout = QVBoxLayout()
        central_widget.setLayout(layout)

        self.log_window = QPlainTextEdit(self)
        self.log_window.setReadOnly(True)
        layout.addWidget(self.log_window)

        self.progress_bar = QProgressBar(self)
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        layout.addWidget(self.progress_bar)

        self.install_button = QPushButton("Install", self)
        self.install_button.clicked.connect(self.start_installation)
        layout.addWidget(self.install_button)

        self.installer_thread = None

    def start_installation(self):
        self.install_button.setEnabled(False)
        self.log_window.clear()
        self.progress_bar.setValue(0)

        self.installer_thread = InstallerThread()
        self.installer_thread.log_signal.connect(self.update_log)
        self.installer_thread.progress_signal.connect(self.update_progress)
        self.installer_thread.error_signal.connect(self.show_error)
        self.installer_thread.finished_signal.connect(self.on_finished)
        self.installer_thread.start()

    def update_log(self, message):
        self.log_window.appendPlainText(message)

    def update_progress(self, value):
        self.progress_bar.setValue(value)

    def show_error(self, message):
        QMessageBox.critical(self, "Error", message)

    def on_finished(self, success, message):
        self.install_button.setEnabled(True)

        if success:
            QMessageBox.information(self, "Completed", message)
        else:
            QMessageBox.warning(self, "Installation failed", message)


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec_())
