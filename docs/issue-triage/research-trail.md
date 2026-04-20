# Issue Triage — Research Trail

Full search-and-source set from the design pass for the [issue-triage spec](README.md). Numbered references in the spec are the subset cited; this file captures the rest so a future reader can see what was considered and where to look to extend the design.

## Search queries

Run against web search in order:

1. `automated bot comments github issues best practices non-authoritative disclaimer`
2. `LLM generated github issue triage antipatterns hallucination 2026`
3. `AI bot code review github best practices avoid mislead developers`
4. `automated triage bot reporter experience noise signal open source`
5. `anthropic claude documentation automated agent transparency disclaimer human oversight`
6. `anthropic claude code best practices agent output github comments review`
7. `anthropic responsible deployment AI agent user trust attribution`
8. `multi-agent LLM adversarial review self-critique hallucination reduction research paper`
9. `retrospective-based evaluation AI systems postmortem SRE outcome ground truth`
10. `structured output JSON schema LLM hallucination reduction OpenAI pydantic`
11. `ast-grep tree-sitter semantic code search static analysis category exclusion`
12. `"adversarial debate" voting LLM multi-agent hallucination reduction paper pdf`

## Sources fetched and read

Outcome annotates whether the source informed the final doc.

| # | URL | Outcome |
|---|-----|---------|
| 1 | [github.blog — AI-supported vulnerability triage with Taskflow Agent](https://github.blog/security/ai-supported-vulnerability-triage-with-the-github-security-lab-taskflow-agent/) | Cited as `github-taskflow` |
| 2 | [docs.github.com — Responsible use of Copilot code review](https://docs.github.com/en/copilot/responsible-use/code-review) | Cited as `github-copilot-review` |
| 3 | [anthropic.com — Framework for safe and trustworthy agents](https://www.anthropic.com/news/our-framework-for-developing-safe-and-trustworthy-agents) | Cited as `anthropic-framework` |
| 4 | [github.com/anthropics/claude-code-security-review](https://github.com/anthropics/claude-code-security-review) | Cited as `anthropic-security-review` |
| 5 | [claude.com — Code Review for Claude Code](https://claude.com/blog/code-review) | Cited as `anthropic-code-review` |
| 6 | [arxiv.org — Agentic AI with Adversarial Self-Critique (2602.13213v1)](https://arxiv.org/html/2602.13213v1) | Cited as `adversarial-self-critique`; numbers verified |
| 7 | [arxiv.org — MARCH (2603.24579v1)](https://arxiv.org/html/2603.24579v1) | Cited as `march-paper`; architecture verified |
| 8 | [developers.openai.com — Structured model outputs](https://developers.openai.com/api/docs/guides/structured-outputs) | Cited as `openai-structured-outputs`; enum-hallucination quote verified |
| 9 | [diffray.ai — LLM Hallucinations in AI Code Review](https://diffray.ai/blog/llm-hallucinations-code-review/) | Cited as `diffray-hallucinations`; verified (numbers cited from NYU / Veracode / university studies) |
| 10 | [engineering.zalando.com — Dead Ends or Data Goldmines](https://engineering.zalando.com/posts/2025/09/dead-ends-or-data-goldmines-ai-powered-postmortem-analysis.html) | Cited as `zalando-postmortems`; initial framing overclaimed, corrected after fetch |
| 11 | [mdpi.com — Adversarial Debate and Voting in LLM Multi-Agents](https://www.mdpi.com/2076-3417/15/7/3676) | **Rejected** — 403 on fetch; dropped to avoid citing unverified source |
| 12 | [ai.pydantic.dev/output/](https://ai.pydantic.dev/output/) | **Rejected** — claim that this documents "optional-field as hallucination prevention" was not supported |
| 13 | [rootly.com — Turn postmortems into actionable learning](https://rootly.com/sre/turn-postmortems-into-actionable-learning-with-rootly-ai) | Cited as `rootly-postmortems`; quote verified |
| 14 | [lakera.ai — LLM Hallucinations in 2026](https://www.lakera.ai/blog/guide-to-hallucinations-in-large-language-models) | Cited as `lakera-hallucinations`; training-incentive claim verified |
| 15 | [ast-grep.github.io](https://ast-grep.github.io/) | Cited as `ast-grep`; wording softened after fetch (programmatic API, not a primary documented use case) |
| 16 | [github.com/trIAgelab/trIAge](https://github.com/trIAgelab/trIAge) | Cited as `triage-project`; archived status noted after fetch |
| 17 | [anthropic.com — Measuring AI agent autonomy in practice](https://www.anthropic.com/research/measuring-agent-autonomy) | Cited as `anthropic-autonomy`; trust-curve figures verified |
| 18 | [code.claude.com — Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices) | Cited as `anthropic-best-practices` |

## Other sources surfaced but not fetched

Relevant search hits not read during this design pass. Kept as an annotated pointer set for future work.

**Multi-agent hallucination-reduction research**
- [Hallucination to Truth: A Review of Fact-Checking and Factuality Evaluation in LLMs](https://arxiv.org/html/2508.03860) — survey, could inform a deeper fact-check stage
- [Mitigating LLM Hallucinations Using a Multi-Agent Framework](https://www.mdpi.com/2078-2489/16/7/517)
- [Mitigating reasoning hallucination through Multi-agent Collaborative Filtering (ScienceDirect)](https://www.sciencedirect.com/science/article/abs/pii/S0957417424025909)
- [Can LLM Agents Really Debate?](https://arxiv.org/html/2511.07784) — critical look at whether debate actually helps
- [Adaptive heterogeneous multi-agent debate](https://link.springer.com/article/10.1007/s44443-025-00353-3)
- [Mitigating Hallucination on Hallucination in RAG via Ensemble Voting](https://arxiv.org/html/2603.27253v1)

**Hallucination in code generation (broader)**
- [Package Hallucinations — USENIX](https://www.usenix.org/publications/loginonline/we-have-package-you-comprehensive-analysis-package-hallucinations-code)
- [Beyond Functional Correctness: Exploring Hallucinations in LLM-Generated Code](https://arxiv.org/html/2404.00971v3)
- [Detecting and Correcting Hallucinations in LLM-Generated Code](https://arxiv.org/pdf/2601.19106)
- [LLM Hallucinations in Practical Code Generation](https://arxiv.org/html/2409.20550v1)
- [Importing Phantoms: Measuring LLM Package Hallucination Vulnerabilities](https://arxiv.org/html/2501.19012v1)
- [Mitigating LLM Hallucinations: A Comprehensive Review](https://www.preprints.org/manuscript/202505.1955)

**Automated triage and review bots (comparative architectures)**
- [Continue — Code Review Bot with GitHub Actions](https://docs.continue.dev/guides/github-pr-review-bot)
- [Cerebro — WRITER's AI security alert triage](https://writer.com/engineering/cerebro-ai-security-alert-triage-system/)
- [twitchax/triage-bot — OpenAI-powered Slack triage bot](https://github.com/twitchax/triage-bot)
- [Simili Bot — openchoreo](https://github.com/openchoreo/openchoreo/issues/2054)
- [anc95/ChatGPT-CodeReview](https://github.com/anc95/ChatGPT-CodeReview)
- [Nikita-Filonov/ai-review](https://github.com/Nikita-Filonov/ai-review)

**SRE postmortems and retrospective tooling**
- [Rootly — AI-Generated Postmortems](https://rootly.com/sre/ai-generated-postmortems-rootlys-automated-rca-tool)
- [Rootly — How to Run Effective Blameless Postmortems](https://rootly.com/incident-postmortems/blameless)
- [FactSet — Improving Reliability Through Blameless Postmortems](https://insight.factset.com/improving-reliability-through-blameless-postmortems)
- [Rootly — Automated Postmortem Tools](https://rootly.com/sre/automated-postmortem-tools-accelerate-engineer-learning)
- [StackGen — How to Automate Alert Triage with AI SREs](https://stackgen.com/blog/how-to-automate-alert-triage-with-ai-sres)

**Structured output and schema-based LLM patterns**
- [Agenta — The guide to structured outputs and function calling](https://agenta.ai/blog/the-guide-to-structured-outputs-and-function-calling-with-llms)
- [Instructor — Structured output for open source and local LLMs](https://python.useinstructor.com/blog/2024/03/07/open-source-local-structured-output-pydantic-json-openai/)
- [Pydantic — How to Use Pydantic for LLMs](https://pydantic.dev/articles/llm-intro)
- [Stop Parsing JSON by Hand (DEV)](https://dev.to/klement_gunndu/stop-parsing-json-by-hand-structured-llm-outputs-with-pydantic-1pg0)
- [Diving Deeper with Structured Outputs (TDS)](https://towardsdatascience.com/diving-deeper-with-structured-outputs-b4a5d280c208/)

**Anthropic — agent framework and review systems (additional)**
- [Claude's Constitution](https://www.anthropic.com/constitution)
- [Anthropic — Research on Trustworthy Agents](https://www.anthropic.com/research/trustworthy-agents)
- [Anthropic Transparency Hub](https://www.anthropic.com/transparency)
- [Anthropic Trust Center](https://trust.anthropic.com/)
- [Claude Code product page](https://www.anthropic.com/product/claude-code)
- [claude-code/plugins/code-review/README](https://github.com/anthropics/claude-code/blob/main/plugins/code-review/README.md)
- [claude-plugins-official — code-review plugin](https://github.com/anthropics/claude-plugins-official/blob/main/plugins/code-review/commands/code-review.md)
- [BigHatGroup — Claude Code Review multi-agent analysis](https://www.bighatgroup.com/blog/claude-code-review-anthropic-multi-agent-github-pr-analysis/)

**GitHub Copilot and community discussions on AI review**
- [Copilot code review overview (GitHub Docs)](https://docs.github.com/en/copilot/tutorials/review-ai-generated-code)
- [AI Code Reviews — GitHub resources](https://github.com/resources/articles/ai-code-reviews)
- [Graphite — Exploring AI code review on GitHub](https://graphite.com/guides/ai-code-review-on-github)
- [GitHub Community — Best Practices for Managing Issues/PRs](https://github.com/orgs/community/discussions/163134)
- [GitHub Community — Allow blocking Copilot-generated issues](https://github.com/orgs/community/discussions/159749)

**ast-grep and structural-search tooling**
- [ast-grep — Core Concepts in Pattern](https://ast-grep.github.io/advanced/core-concepts.html)
- [ast-grep — How ast-grep Works](https://ast-grep.github.io/advanced/how-ast-grep-works.html)
- [ast-grep — Comparison with other frameworks](https://ast-grep.github.io/advanced/tool-comparison.html)
- [Semantic Code Indexing with AST and Tree-sitter for AI Agents](https://medium.com/@email2dineshkuppan/semantic-code-indexing-with-ast-and-tree-sitter-for-ai-agents-part-1-of-3-eb5237ba687a)
