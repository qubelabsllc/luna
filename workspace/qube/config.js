// Supabase project settings. Both values are public by design: the anon key
// only allows what the database's row-level security and functions permit.
// Find them in Supabase → Project Settings → API.
window.QUBE_CONFIG = {
  supabaseUrl: "",
  supabaseAnonKey: "",

  // Used only while Supabase isn't connected: one invite-only account that
  // lives in the browser. Email and access code are stored as SHA-256 hashes.
  // This is a front door, not security; anything client-side can be bypassed.
  preview: {
    handle: "qube",
    emailSha256: "e878511d0b3cf71e23ee953b94dadc003f6b0116244d69eda2a48348f06b622c",
    codeSha256: "54832ed0c620b761802295cde0672596f69bfd564749abd4de5472e4b9c4e679",
  },
};
