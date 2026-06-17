#!/usr/bin/env python3
# gpu_exporter.py — minimal NVML -> Prometheus exporter.
#
# Gcore Everywhere Inference is a managed, non-privileged container, so the usual
# node-level NVIDIA dcgm-exporter can't run here (its embedded nv-hostengine needs
# CAP_SYS_ADMIN, which the platform won't grant). NVML, however, is already used
# by vLLM and needs no extra privileges. This exporter reads NVML and emits the
# *exact* DCGM_FI_DEV_* metric names the InfraTailors Grafana panels query
# (DCGM_FI_DEV_GPU_UTIL / _FB_USED / _FB_FREE, with a numeric `gpu` label), so the
# existing GPU panels light up without any dashboard changes.
#
# Listens on 127.0.0.1:9400; Grafana Alloy (in the same container) scrapes it and
# remote-writes with the deployment-identity labels. Best-effort: if NVML is
# unavailable it returns 500 and the container keeps serving (vLLM stays the
# health-determining process).
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

import pynvml

PORT = int(os.environ.get("GPU_EXPORTER_PORT", "9400"))


def _s(v):
    return v.decode() if isinstance(v, bytes) else v


def collect() -> str:
    pynvml.nvmlInit()
    try:
        n = pynvml.nvmlDeviceGetCount()
        lines = [
            "# TYPE DCGM_FI_DEV_GPU_UTIL gauge",
            "# TYPE DCGM_FI_DEV_MEM_COPY_UTIL gauge",
            "# TYPE DCGM_FI_DEV_FB_USED gauge",
            "# TYPE DCGM_FI_DEV_FB_FREE gauge",
            "# TYPE DCGM_FI_DEV_POWER_USAGE gauge",
            "# TYPE DCGM_FI_DEV_GPU_TEMP gauge",
            "# TYPE DCGM_FI_DEV_SM_CLOCK gauge",
            "# TYPE DCGM_FI_DEV_MEM_CLOCK gauge",
            "# TYPE DCGM_FI_DEV_ENC_UTIL gauge",
            "# TYPE DCGM_FI_DEV_DEC_UTIL gauge",
        ]
        for i in range(n):
            h = pynvml.nvmlDeviceGetHandleByIndex(i)
            uuid = _s(pynvml.nvmlDeviceGetUUID(h))
            try:
                name = _s(pynvml.nvmlDeviceGetName(h))
            except Exception:
                name = "unknown"
            lbl = f'gpu="{i}",UUID="{uuid}",modelName="{name}"'
            util = pynvml.nvmlDeviceGetUtilizationRates(h)
            mem = pynvml.nvmlDeviceGetMemoryInfo(h)
            lines.append(f"DCGM_FI_DEV_GPU_UTIL{{{lbl}}} {util.gpu}")
            # NVML util.memory = % time the memory bus was busy ~ DCGM MEM_COPY_UTIL.
            lines.append(f"DCGM_FI_DEV_MEM_COPY_UTIL{{{lbl}}} {util.memory}")
            # DCGM FB_USED/FREE are MiB; NVML returns bytes -> convert.
            lines.append(f"DCGM_FI_DEV_FB_USED{{{lbl}}} {mem.used // (1024 * 1024)}")
            lines.append(f"DCGM_FI_DEV_FB_FREE{{{lbl}}} {mem.free // (1024 * 1024)}")
            try:
                lines.append(
                    f"DCGM_FI_DEV_POWER_USAGE{{{lbl}}} {pynvml.nvmlDeviceGetPowerUsage(h) / 1000.0}"
                )
            except Exception:
                pass
            try:
                lines.append(
                    f"DCGM_FI_DEV_GPU_TEMP{{{lbl}}} "
                    f"{pynvml.nvmlDeviceGetTemperature(h, pynvml.NVML_TEMPERATURE_GPU)}"
                )
            except Exception:
                pass
            try:  # clocks in MHz (DCGM SM_CLOCK / MEM_CLOCK are MHz too)
                lines.append(
                    f"DCGM_FI_DEV_SM_CLOCK{{{lbl}}} "
                    f"{pynvml.nvmlDeviceGetClockInfo(h, pynvml.NVML_CLOCK_SM)}"
                )
                lines.append(
                    f"DCGM_FI_DEV_MEM_CLOCK{{{lbl}}} "
                    f"{pynvml.nvmlDeviceGetClockInfo(h, pynvml.NVML_CLOCK_MEM)}"
                )
            except Exception:
                pass
            try:  # encoder/decoder utilization % (first element of the tuple)
                lines.append(f"DCGM_FI_DEV_ENC_UTIL{{{lbl}}} {pynvml.nvmlDeviceGetEncoderUtilization(h)[0]}")
                lines.append(f"DCGM_FI_DEV_DEC_UTIL{{{lbl}}} {pynvml.nvmlDeviceGetDecoderUtilization(h)[0]}")
            except Exception:
                pass
        return "\n".join(lines) + "\n"
    finally:
        try:
            pynvml.nvmlShutdown()
        except Exception:
            pass


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        try:
            body = collect().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:  # NVML unavailable / blocked -> surface, stay alive
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def log_message(self, *_):  # quiet
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
