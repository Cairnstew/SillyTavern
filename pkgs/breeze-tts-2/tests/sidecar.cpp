// Behavioral test for the fork-local per-voice generation defaults patch.
//
// The .breeze files are synthetic: the loader only validates the container, and
// generation is never started, so this needs neither a GGUF nor a GPU. It pins
// the precedence the module promises:
//
//   request field > <name>.json > GenRequest default
//
// and the 404 for an unknown voice.
#include "openai.h"
#include "voices.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

using namespace breeze;

static int failures = 0;

#define CHECK(cond) \
    do { \
        if (!(cond)) { \
            std::cerr << "FAIL line " << __LINE__ << ": " #cond "\n"; \
            failures++; \
        } \
    } while (0)

static bool put32(FILE * f, uint32_t v) { return fwrite(&v, 4, 1, f) == 1; }

static bool put_str(FILE * f, const std::string & s) {
    return put32(f, (uint32_t) s.size()) &&
           (s.empty() || fwrite(s.data(), 1, s.size(), f) == s.size());
}

// v1 container: magic, version, sample rate, codebooks, frames, transcript,
// then frames * codebooks int32 codes. One frame is enough for the loader.
static void write_voice(const std::filesystem::path & path) {
    FILE * f = fopen(path.c_str(), "wb");
    if (!f) {
        std::cerr << "cannot create " << path << "\n";
        std::exit(2);
    }
    fwrite("BRZV", 1, 4, f);
    put32(f, 1);
    put32(f, 24000);
    put32(f, 16);
    put32(f, 1);
    put_str(f, "reference transcript");
    for (int i = 0; i < 16; i++) put32(f, (uint32_t) i);
    fclose(f);
}

static void write_text(const std::filesystem::path & path, const std::string & text) {
    std::ofstream out(path);
    out << text;
}

static bool parse(VoiceStore & store, const std::string & body, OpenAiSpeech & out, int & status) {
    const std::string err = parse_openai_speech(body, store, 300, out, status);
    if (!err.empty()) {
        std::cerr << "unexpected parse error: " << err << "\n";
        return false;
    }
    return true;
}

int main(int argc, char ** argv) {
    const std::filesystem::path dir = argc > 1 ? argv[1] : "voices";
    std::filesystem::create_directories(dir);

    write_voice(dir / "Widowmaker.breeze");
    write_voice(dir / "NoDefaults.breeze");
    write_voice(dir / "SplitDefaults.breeze");
    write_text(
        dir / "Widowmaker.json",
        R"({"instructions":"Speak coldly.","cfg_scale":2.0,"seed":7,"temperature":0.9,"top_k":50,"top_p":1.0,"repetition_penalty":1.1,"max_new_tokens":750})");
    write_text(dir / "SplitDefaults.json", R"({"split_chars":180})");

    VoiceStore store;
    store.load_dir(dir.string(), 16);

    OpenAiSpeech out;
    int status = 0;

    // The sidecar supplies everything the request does not.
    CHECK(parse(store, R"({"input":"hello","voice":"Widowmaker"})", out, status));
    CHECK(status == 200);
    CHECK(out.g.instruction == "Speak coldly.");
    CHECK(out.g.cfg_scale == 2.0f);
    CHECK(out.g.seed == 7);
    CHECK(out.g.temperature == 0.9f);
    CHECK(out.g.top_k == 50);
    CHECK(out.g.top_p == 1.0f);
    CHECK(out.g.repetition_penalty == 1.1f);
    CHECK(out.g.max_new_tokens == 750);
    CHECK(out.g.split_chars == 300); // sidecar has no split_chars; server default wins

    // An explicit request field wins over the sidecar.
    out = OpenAiSpeech();
    CHECK(parse(
        store,
        R"({"input":"hello","voice":"Widowmaker","instructions":"Shout it.","cfg_scale":3.0,"seed":1,"temperature":0.5,"top_k":10,"top_p":0.8,"repetition_penalty":1.2,"max_new_tokens":100,"split_chars":120})",
        out,
        status));
    CHECK(out.g.instruction == "Shout it.");
    CHECK(out.g.cfg_scale == 3.0f);
    CHECK(out.g.seed == 1);
    CHECK(out.g.temperature == 0.5f);
    CHECK(out.g.top_k == 10);
    CHECK(out.g.top_p == 0.8f);
    CHECK(out.g.repetition_penalty == 1.2f);
    CHECK(out.g.max_new_tokens == 100);
    CHECK(out.g.split_chars == 120);

    // A voice without a sidecar keeps the server/GenRequest defaults.
    out = OpenAiSpeech();
    CHECK(parse(store, R"({"input":"hello","voice":"NoDefaults"})", out, status));
    CHECK(out.g.instruction == "Speak clearly and naturally.");
    CHECK(out.g.cfg_scale == 1.0f);
    CHECK(out.g.seed == 42);
    CHECK(out.g.temperature == 0.0f);
    CHECK(out.g.top_k == 0);
    CHECK(out.g.max_new_tokens == 0);
    CHECK(out.g.split_chars == 300);

    // A sidecar split_chars beats the server default.
    out = OpenAiSpeech();
    CHECK(parse(store, R"({"input":"hello","voice":"SplitDefaults"})", out, status));
    CHECK(out.g.split_chars == 180);

    // An unknown voice is still a 404.
    out = OpenAiSpeech();
    const std::string err =
        parse_openai_speech(R"({"input":"hello","voice":"Missing"})", store, 300, out, status);
    CHECK(!err.empty());
    CHECK(status == 404);

    if (failures == 0) std::cout << "PASS sidecar defaults\n";
    return failures == 0 ? 0 : 1;
}
