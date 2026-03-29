export default function (api: any) {
  const config = api.config?.plugins?.entries?.["exa-search"]?.config;
  const apiKey = config?.apiKey || process.env.EXA_API_KEY;

  api.registerTool(
    {
      name: "exa_search",
      description:
        "Search the web using Exa, an AI-native search engine. Supports neural (meaning-based), keyword, and auto search modes. Returns titles, URLs, and optionally full page text.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "The search query.",
          },
          numResults: {
            type: "number",
            description: "Number of results to return (default: 5, max: 10).",
            default: 5,
          },
          type: {
            type: "string",
            enum: ["auto", "keyword", "neural"],
            description:
              "Search type: 'neural' for meaning-based, 'keyword' for traditional, 'auto' to let Exa decide.",
            default: "auto",
          },
          useAutoprompt: {
            type: "boolean",
            description:
              "Let Exa rephrase the query for better neural search results.",
            default: true,
          },
          category: {
            type: "string",
            enum: [
              "company",
              "research paper",
              "news",
              "github",
              "tweet",
              "movie",
              "song",
              "personal site",
              "pdf",
            ],
            description: "Optional: filter results to a specific category.",
          },
          startPublishedDate: {
            type: "string",
            description:
              "Optional: only results published after this date (ISO 8601, e.g. 2024-01-01T00:00:00.000Z).",
          },
          endPublishedDate: {
            type: "string",
            description:
              "Optional: only results published before this date (ISO 8601).",
          },
          includeDomains: {
            type: "array",
            items: { type: "string" },
            description:
              "Optional: only include results from these domains (e.g. ['arxiv.org', 'github.com']).",
          },
          excludeDomains: {
            type: "array",
            items: { type: "string" },
            description:
              "Optional: exclude results from these domains.",
          },
          includeText: {
            type: "boolean",
            description:
              "Whether to include extracted page text in results (default: true).",
            default: true,
          },
        },
        required: ["query"],
      },
      async execute(_id: string, params: any) {
        if (!apiKey) {
          return {
            content: [
              {
                type: "text",
                text: "Exa API key not configured. Set EXA_API_KEY in environment or configure plugins.entries.exa-search.config.apiKey.",
              },
            ],
          };
        }

        const numResults = Math.min(params.numResults ?? 5, 10);

        const body: Record<string, any> = {
          query: params.query,
          numResults,
          type: params.type ?? "auto",
          useAutoprompt: params.useAutoprompt ?? true,
        };

        // Optional filters
        if (params.category) body.category = params.category;
        if (params.startPublishedDate)
          body.startPublishedDate = params.startPublishedDate;
        if (params.endPublishedDate)
          body.endPublishedDate = params.endPublishedDate;
        if (params.includeDomains) body.includeDomains = params.includeDomains;
        if (params.excludeDomains) body.excludeDomains = params.excludeDomains;

        // Content retrieval
        if (params.includeText !== false) {
          body.contents = { text: { maxCharacters: 3000 } };
        }

        try {
          const res = await fetch("https://api.exa.ai/search", {
            method: "POST",
            headers: {
              "x-api-key": apiKey,
              "Content-Type": "application/json",
            },
            body: JSON.stringify(body),
          });

          if (!res.ok) {
            const errText = await res.text();
            return {
              content: [
                {
                  type: "text",
                  text: `Exa API error (${res.status}): ${errText}`,
                },
              ],
            };
          }

          const data = await res.json();
          const results = (data.results ?? []).map((r: any) => ({
            title: r.title,
            url: r.url,
            publishedDate: r.publishedDate,
            author: r.author,
            score: r.score,
            text: r.text?.substring(0, 3000),
          }));

          if (results.length === 0) {
            return {
              content: [
                { type: "text", text: "No results found for this query." },
              ],
            };
          }

          const formatted = results
            .map(
              (r: any, i: number) =>
                `**${i + 1}. ${r.title || "Untitled"}**\n${r.url}${r.publishedDate ? `\nPublished: ${r.publishedDate}` : ""}${r.author ? `\nAuthor: ${r.author}` : ""}${r.score ? `\nRelevance: ${(r.score * 100).toFixed(1)}%` : ""}${r.text ? `\n\n${r.text}` : ""}`
            )
            .join("\n\n---\n\n");

          return {
            content: [{ type: "text", text: formatted }],
          };
        } catch (err: any) {
          return {
            content: [
              {
                type: "text",
                text: `Exa search failed: ${err.message}`,
              },
            ],
          };
        }
      },
    },
    { optional: true }
  );
}
