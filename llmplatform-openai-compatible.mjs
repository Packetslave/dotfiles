import { createOpenAICompatible as createBaseOpenAICompatible } from '@ai-sdk/openai-compatible';

function stripCacheControl(value) {
  if (Array.isArray(value)) {
    return value.map(stripCacheControl);
  }
  if (!value || typeof value !== 'object') {
    return value;
  }

  const next = {};
  for (const [key, nested] of Object.entries(value)) {
    if (key === 'cache_control' || key === 'cacheControl') {
      continue;
    }
    next[key] = stripCacheControl(nested);
  }
  return next;
}

export function createOpenAICompatible(options = {}) {
  const upstreamTransform = typeof options.transformRequestBody === 'function'
    ? options.transformRequestBody
    : undefined;

  return createBaseOpenAICompatible({
    ...options,
    includeUsage: options.includeUsage ?? true,
    transformRequestBody(args) {
      const transformed = upstreamTransform ? upstreamTransform(args) : args;
      return stripCacheControl(transformed);
    },
  });
}
