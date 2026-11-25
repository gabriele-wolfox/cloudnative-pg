# llm-d

llm-d is a Kubernetes-native distributed inference serving stack for large
language models. It uses vLLM as the model server and adds an inference
gateway that routes requests with prefix-cache and load awareness, plus
support for disaggregated prefill and decode. It exposes an OpenAI-compatible
API, so any OpenAI client can talk to it.
