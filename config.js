// EBK site config. Fill these in from your Supabase project: Project Settings -> API.
//
// Both values are safe to publish: the key below is the PUBLIC one ("anon" / "publishable").
// supabase/schema.sql decides what it is allowed to do. Never paste the "service_role" or
// "secret" key here.
//
// Leave them empty and the game still runs, it just won't record answers or show live rarity.
window.EBK_CONFIG = {
  supabaseUrl: "",        // e.g. "https://abcdefgh.supabase.co"
  supabaseAnonKey: "",    // the "anon public" key (or the newer "sb_publishable_..." key)
  puzzlesPath: "puzzles"  // folder holding YYYY-MM-DD.json files + index.json
};
