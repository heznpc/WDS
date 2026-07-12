export class ContextJudgeError extends Error {
  constructor(message, { status = 0, code = "judge_failed" } = {}) {
    super(message);
    this.name = "ContextJudgeError";
    this.status = status;
    this.code = code;
  }
}

export async function requestContextJudgment(payload, { signal, timeoutMs = 15_000 } = {}) {
  const controller = new AbortController();
  const abortFromParent = () => controller.abort(signal?.reason);
  signal?.addEventListener("abort", abortFromParent, { once: true });
  const timeout = window.setTimeout(() => controller.abort("timeout"), timeoutMs);

  try {
    const response = await fetch("/api/context-judge", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });

    let body = null;
    try {
      body = await response.json();
    } catch {
      throw new ContextJudgeError("판정 응답을 읽지 못했습니다.", {
        status: response.status,
        code: "invalid_response",
      });
    }

    if (!response.ok) {
      throw new ContextJudgeError("문맥 판정을 사용할 수 없습니다.", {
        status: response.status,
        code: typeof body?.error === "string" ? body.error : "judge_failed",
      });
    }

    return body;
  } catch (error) {
    if (error instanceof ContextJudgeError) throw error;
    if (controller.signal.aborted) {
      throw new ContextJudgeError("문맥 판정이 취소됐습니다.", {
        code: signal?.aborted ? "aborted" : "timeout",
      });
    }
    throw new ContextJudgeError("문맥 판정에 연결하지 못했습니다.", {
      code: "network_error",
    });
  } finally {
    window.clearTimeout(timeout);
    signal?.removeEventListener("abort", abortFromParent);
  }
}
