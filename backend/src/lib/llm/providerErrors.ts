import { UserFacingError } from "../userFacingError";

type ProviderContext = { label: string; modelId: string };

type ApiCallErrorLike = Error & { statusCode: number; responseBody?: string };

// The AI SDK is ESM-only here, so match its error shapes rather than importing
// APICallError / RetryError classes.
function findApiCallError(error: unknown): ApiCallErrorLike | null {
  if (!(error instanceof Error)) return null;
  if (typeof (error as Partial<ApiCallErrorLike>).statusCode === "number") {
    return error as ApiCallErrorLike;
  }
  const lastError = (error as { lastError?: unknown }).lastError;
  return lastError === undefined ? null : findApiCallError(lastError);
}

function userFacingMessage(
  { statusCode, responseBody = "" }: ApiCallErrorLike,
  { label, modelId }: ProviderContext,
): string | null {
  if (statusCode === 401 || /api[ _]?key[ _](not[ _]valid|invalid)/i.test(responseBody)) {
    return `Your ${label} API key was rejected. Check the key in your account settings.`;
  }
  if (statusCode === 402) {
    return `Your ${label} account is out of credits. Top up, or select another model.`;
  }
  if (statusCode === 403 || statusCode === 404) {
    return `${modelId} isn't available with your ${label} API key. Select another model.`;
  }
  if (statusCode === 429) {
    return /limit: 0\b/.test(responseBody)
      ? `Your ${label} plan doesn't include ${modelId}. Select another model, or upgrade your ${label} plan.`
      : `${label} rate limit or quota reached. Wait a moment and try again, or select another model.`;
  }
  return null;
}

/** Turn provider access failures into messages the chat can show the user. */
export function toProviderStreamError(
  error: unknown,
  context: ProviderContext,
): Error {
  const apiError = findApiCallError(error);
  const message = apiError && userFacingMessage(apiError, context);
  if (message) return new UserFacingError(message);
  if (error instanceof Error && error.message) return error;
  if (typeof error === "string" && error.trim()) return new Error(error);
  return new Error(`${context.label} stream failed.`);
}
