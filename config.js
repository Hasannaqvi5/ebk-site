// EBK site config. Fill these in from your Supabase project: Project Settings -> API.
//
// Both values are safe to publish: the key below is the PUBLIC one ("anon" / "publishable").
// supabase/schema.sql decides what it is allowed to do. Never paste the "service_role" or
// "secret" key here.
//
// Leave them empty and the game still runs, it just won't record answers or show live rarity.
window.EBK_CONFIG = {
  supabaseUrl: "https://xvtpxkmlsolqrvjwflxq.supabase.co",
  supabaseAnonKey: "sb_publishable_9SWoj7UJaZuCh9q3I6wfeA_oQ6lATsx",  // public "publishable" key
  puzzlesPath: "puzzles"  // folder holding YYYY-MM-DD.json files + index.json
};
