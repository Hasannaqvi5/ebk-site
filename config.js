// EBK site config. Fill these in from Supabase: Project Settings -> API.
// The anon key is meant to be public; Row Level Security in supabase/schema.sql protects the data.
// Leave them empty and the game still runs, it just won't record answers or load live rarity.
window.EBK_CONFIG = {
  supabaseUrl: "",        // e.g. "https://abcdefgh.supabase.co"
  supabaseAnonKey: "",    // the "anon public" key
  puzzlesPath: "puzzles"  // folder holding YYYY-MM-DD.json files + index.json
};
