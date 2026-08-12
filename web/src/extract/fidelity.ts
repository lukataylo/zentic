// Is fidelity load-bearing on this page?
//
// `ExtractionResult.isFidelitySensitive` gates the rewrite layer: news, medical,
// legal and financial content needs an explicit per-page confirm before a model
// re-voices it, because re-voicing those is a claim about what someone said, what
// a drug does, what a contract requires, or what a company reported.
//
// Tuned to over-report. A false positive costs one extra tap; a false negative
// costs a paraphrased dosage.

const SENSITIVE_HOST_FRAGMENTS = [
  // News
  "news",
  "bbc.",
  "cnn.",
  "reuters",
  "apnews",
  "npr.org",
  "guardian",
  "nytimes",
  "wsj.com",
  "ft.com",
  "washingtonpost",
  "bloomberg",
  "aljazeera",
  "politico",
  "propublica",
  "economist",
  "telegraph.co.uk",
  "independent.co.uk",
  // Medical
  "nih.gov",
  "ncbi.nlm",
  "who.int",
  "cdc.gov",
  "mayoclinic",
  "webmd",
  "healthline",
  "nhs.uk",
  "medscape",
  "thelancet",
  "nejm.org",
  "bmj.com",
  "plos.org",
  "drugs.com",
  "medlineplus",
  // Legal
  "law.cornell",
  "supremecourt",
  "justice.gov",
  "courtlistener",
  "legislation.gov",
  "eur-lex",
  "gov.uk",
  ".gov",
  // Financial
  "sec.gov",
  "investor.",
  "finance.",
  "investopedia",
  "morningstar",
  "marketwatch",
  "fool.com",
  "irs.gov",
  "federalreserve",
];

const SENSITIVE_PATH_FRAGMENTS = [
  "/news/",
  "/politics/",
  "/health/",
  "/medicine/",
  "/legal/",
  "/law/",
  "/finance/",
  "/markets/",
  "/investing/",
  "/tax/",
  "/uscode/",
  "/edgar/",
];

/** Schema.org types that name regulated subject matter. */
const SENSITIVE_SCHEMA =
  /"@type"\s*:\s*"?(NewsArticle|ReportageNewsArticle|MedicalWebPage|MedicalScholarlyArticle|Drug|MedicalCondition|Legislation|FinancialProduct|Course)/;

/**
 * Phrases that only appear when the details matter.
 *
 * Single words would be far too eager ("court" in a tennis article). These are
 * mostly bigrams for that reason, and they are matched against the extracted
 * text rather than the whole page so navigation chrome cannot trip them.
 */
const SENSITIVE_PHRASES = [
  "mg per",
  "mg/kg",
  "dosage",
  "side effects",
  "contraindicat",
  "clinical trial",
  "placebo",
  "diagnosis",
  "symptoms include",
  "prescribed",
  "randomised controlled",
  "randomized controlled",
  "plaintiff",
  "defendant",
  "the court held",
  "pursuant to",
  "shall be liable",
  "statute",
  "indicted",
  "guilty plea",
  "settlement agreement",
  "earnings per share",
  "net revenue",
  "fiscal year",
  "interest rate",
  "basis points",
  "shareholders",
  "prospectus",
  "not financial advice",
  "according to police",
  "officials said",
  "the government said",
];

export interface FidelityInput {
  url: string;
  title: string;
  /** Extracted prose. Kept to the first few thousand characters — enough to judge. */
  text: string;
  /** Raw text of JSON-LD blocks, if any. */
  schema: string;
}

export function isFidelitySensitive(input: FidelityInput): boolean {
  let host = "";
  let path = "";
  try {
    const url = new URL(input.url);
    host = url.hostname.toLowerCase();
    path = url.pathname.toLowerCase();
  } catch {
    // A page with no parseable URL gets judged on its text alone.
  }

  if (SENSITIVE_SCHEMA.test(input.schema)) return true;
  if (SENSITIVE_HOST_FRAGMENTS.some((fragment) => host.includes(fragment))) return true;
  if (SENSITIVE_PATH_FRAGMENTS.some((fragment) => path.includes(fragment))) return true;

  const haystack = `${input.title}\n${input.text}`.toLowerCase();
  // Two phrases, not one: a single incidental match ("statute" in a history
  // essay) is not enough to make the reader confirm a rewrite.
  let hits = 0;
  for (const phrase of SENSITIVE_PHRASES) {
    if (haystack.includes(phrase)) {
      hits += 1;
      if (hits >= 2) return true;
    }
  }

  return false;
}
