// Ported assertions from the Model.js checks; run with `node test/model-test.js`.
const M = require('../Model.js')
const assert = require('assert')

// HF reference parsing
assert.deepStrictEqual(M.parseHfRef("owner/repo"), {hfRepo:"owner/repo", hfFile:"", quant:""})
assert.deepStrictEqual(M.parseHfRef("owner/repo:Q4_K_M"), {hfRepo:"owner/repo", hfFile:"", quant:"Q4_K_M"})
assert.deepStrictEqual(M.parseHfRef("https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/blob/main/qwen2.5-7b-instruct-q4_k_m.gguf"),
  {hfRepo:"Qwen/Qwen2.5-7B-Instruct-GGUF", hfFile:"qwen2.5-7b-instruct-q4_k_m.gguf", quant:""})
assert.deepStrictEqual(M.parseHfRef("hf://bartowski/Llama-3.1-8B-Instruct-GGUF"), {hfRepo:"bartowski/Llama-3.1-8B-Instruct-GGUF", hfFile:"", quant:""})
assert.deepStrictEqual(M.parseHfRef("www.huggingface.co/owner/repo/resolve/main/a.gguf"), {hfRepo:"owner/repo", hfFile:"a.gguf", quant:""})
assert.deepStrictEqual(M.parseHfRef("owner/repo/blob/main/x.gguf"), {hfRepo:"owner/repo", hfFile:"x.gguf", quant:""})
assert.deepStrictEqual(M.parseHfRef(""), {hfRepo:"", hfFile:"", quant:""})
assert.deepStrictEqual(M.parseHfRef("Qwen/Qwen2.5-7B-Instruct-GGUF:Q5_K_M"), {hfRepo:"Qwen/Qwen2.5-7B-Instruct-GGUF", hfFile:"", quant:"Q5_K_M"})

// Clamps
assert.strictEqual(M.clampCtx("8192"), 8192)
assert.strictEqual(M.clampCtx("bogus"), 8192)
assert.strictEqual(M.clampCtx(500), 500)
assert.strictEqual(M.clampCtx(500000), 262144)
assert.strictEqual(M.clampLayers(999), 999)
assert.strictEqual(M.clampMoe("4"), 4)

// Prometheus-style metrics (names from llama-server build 10667)
const txt = "# HELP x\nllamacpp:prompt_tokens_total 123\nllamacpp:tokens_predicted_total 456\nllamacpp:request_count_total 7\n# TYPE y counter\n"
const met = M.parseMetrics(txt)
assert.strictEqual(met.available, true)
assert.strictEqual(met.promptTokens, 123)
assert.strictEqual(met.predictedTokens, 456)
assert.strictEqual(met.requestCount, 7)

// /slots JSON
const slots = M.parseSlots('[{"n_past":10,"n_predicted":5},{"n_past":0,"n_predicted":0},{},{"id":3,"n_past":2}]')
assert.strictEqual(slots.total, 4)
assert.strictEqual(slots.active, 2)
assert.strictEqual(slots.predicted, 5)

// Formatting
assert.strictEqual(M.humanCtx(8192), "8k")
assert.strictEqual(M.humanCtx(4096), "4k")
assert.strictEqual(M.humanTokens(1200), "1.2k")
assert.strictEqual(M.formatRate(42), "42 t/s")
assert.strictEqual(M.suggestName({name:"Qwen 2.5", hfRepo:"a/b"}), "Qwen 2.5")
assert.strictEqual(M.suggestName({hfRepo:"a/b"}), "b")
assert.strictEqual(M.statusTooltip({name:"Qwen", ctxSize:8192}, {active:2}), "LLaMA.cpp Loader\nQwen\nctx 8k\n2 active slots")

console.log("OK: all Model.js assertions passed")
