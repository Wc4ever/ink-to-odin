using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using Ink.Runtime;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using SysPath = System.IO.Path; // disambiguate from Ink.Runtime.Path

// Generates golden test logs by playing a compiled ink fixture with inkle's
// reference runtime (vendored ink-engine-runtime). Each log captures every
// public observable AND the full state.ToJson() snapshot per step, so our
// Odin port can byte-diff its output against this as ground truth.
//
// Usage:
//   dotnet run --project tools/ink-test-runner [fixture]
//   dotnet run --project tools/ink-test-runner all
//
// `fixture` is a directory name under tests/fixtures/. If omitted, all
// fixtures are processed. Each fixture's logs go to
// tests/golden/reference/<fixture>/seed_{0..9}.log.

internal static class Program
{
	const int SeedCount = 10;
	const int TurnLimit = 500;

	// Resolved from AppContext.BaseDirectory which is bin/Debug/net9.0/.
	// Up 5 lands at ink-to-odin/.
	const string FixturesRel = "../../../../../tests/fixtures";
	const string LogsBaseRel = "../../../../../tests/golden/reference";

	static int Main(string[] args)
	{
		string projectDir   = AppContext.BaseDirectory;
		string fixturesRoot = SysPath.GetFullPath(SysPath.Combine(projectDir, FixturesRel));
		string logsRoot     = SysPath.GetFullPath(SysPath.Combine(projectDir, LogsBaseRel));

		if (!Directory.Exists(fixturesRoot)) {
			Console.Error.WriteLine("Fixtures dir not found at " + fixturesRoot);
			return 1;
		}

		var fixtures = new List<string>();
		if (args.Length == 0 || args[0] == "all") {
			foreach (var dir in Directory.EnumerateDirectories(fixturesRoot)) {
				fixtures.Add(SysPath.GetFileName(dir));
			}
			fixtures.Sort(StringComparer.Ordinal);
		} else {
			fixtures.Add(args[0]);
		}

		foreach (var name in fixtures) {
			int rc = RunFixture(fixturesRoot, logsRoot, name);
			if (rc != 0) return rc;
		}
		return 0;
	}

	static int RunFixture(string fixturesRoot, string logsRoot, string name)
	{
		string fixtureDir = SysPath.Combine(fixturesRoot, name);
		if (!Directory.Exists(fixtureDir)) {
			Console.Error.WriteLine("Fixture dir not found: " + fixtureDir);
			return 1;
		}

		// Pick the first *.ink.json under the fixture dir.
		var jsonFiles = Directory.GetFiles(fixtureDir, "*.ink.json");
		if (jsonFiles.Length == 0) {
			Console.Error.WriteLine("No *.ink.json in " + fixtureDir);
			return 1;
		}
		string storyPath = jsonFiles[0];

		string logsDir = SysPath.Combine(logsRoot, name);
		Directory.CreateDirectory(logsDir);

		string storyJson = File.ReadAllText(storyPath);
		for (int seed = 0; seed < SeedCount; seed++) {
			string log = RunSeed(storyJson, seed);
			string outPath = SysPath.Combine(logsDir, "seed_" + seed + ".log");
			File.WriteAllText(outPath, log);
			Console.WriteLine("Wrote " + outPath);
		}
		Console.WriteLine("Wrote " + SeedCount + " logs to " + logsDir);
		return 0;
	}

	static string RunSeed(string storyJson, int seed)
	{
		var story = new Story(storyJson);
		// Fixtures use `EXTERNAL` declarations backed by ink-side functions of
		// the same name; both the dotnet runner and the Odin runtime need this
		// flag enabled so the runtime falls back to those functions instead of
		// erroring on unbound externals.
		story.allowExternalFunctionFallbacks = true;
		SeedStoryRng(story, seed);
		var pickRng = new Random(seed);

		var sb = new StringBuilder();
		sb.AppendLine("SEED " + seed);
		sb.AppendLine("TURN_LIMIT " + TurnLimit);
		sb.AppendLine();

		AppendStep(sb, 0, "initial", story);

		int step = 1;
		int turn = 0;
		string halt = "end_of_story";

		while (turn < TurnLimit) {
			while (story.canContinue) {
				string text = story.Continue();
				sb.AppendLine("=== STEP " + step + " (continue) ===");
				sb.AppendLine("OUTPUT " + Quote(text));
				AppendTags(sb, story.currentTags);
				AppendErrorsAndWarnings(sb, story);
				AppendStateJson(sb, story);
				step++;
			}

			AppendErrorsAndWarnings(sb, story);

			var choices = story.currentChoices;
			if (choices == null || choices.Count == 0) {
				sb.AppendLine("=== END ===");
				break;
			}

			sb.AppendLine("CHOICES " + choices.Count);
			for (int i = 0; i < choices.Count; i++) {
				var c = choices[i];
				sb.AppendLine("  [" + i + "] " + Quote(c.text)
					+ " index=" + c.index
					+ " pathOnChoice=" + (ReflectString(c, "pathStringOnChoice") ?? "")
					+ " threadAtGen=" + ReflectThreadIndex(c));
			}

			int pick = pickRng.Next() % choices.Count;
			if (pick < 0) pick += choices.Count;
			sb.AppendLine("PICK " + pick);
			story.ChooseChoiceIndex(pick);
			turn++;

			AppendStep(sb, step, "after_pick", story);
			step++;
		}

		if (turn >= TurnLimit) {
			sb.AppendLine("=== HALT_TURN_LIMIT ===");
			halt = "turn_limit";
		}

		sb.AppendLine();
		sb.AppendLine("TOTAL_STEPS " + (step - 1));
		sb.AppendLine("TURNS " + turn);
		sb.AppendLine("HALT_REASON " + halt);
		return sb.ToString();
	}

	static void AppendStep(StringBuilder sb, int step, string label, Story story)
	{
		sb.AppendLine("=== STEP " + step + " (" + label + ") ===");
		AppendTags(sb, story.currentTags);
		AppendErrorsAndWarnings(sb, story);
		AppendStateJson(sb, story);
	}

	static void AppendTags(StringBuilder sb, IList<string> tags)
	{
		if (tags == null || tags.Count == 0) {
			sb.AppendLine("TAGS []");
			return;
		}
		sb.Append("TAGS [");
		for (int i = 0; i < tags.Count; i++) {
			if (i > 0) sb.Append(", ");
			sb.Append(Quote(tags[i]));
		}
		sb.AppendLine("]");
	}

	static void AppendErrorsAndWarnings(StringBuilder sb, Story story)
	{
		if (story.hasError && story.currentErrors != null) {
			foreach (var e in story.currentErrors) sb.AppendLine("ERROR " + Quote(e));
		}
		if (story.hasWarning && story.currentWarnings != null) {
			foreach (var w in story.currentWarnings) sb.AppendLine("WARNING " + Quote(w));
		}
	}

	static void AppendStateJson(StringBuilder sb, Story story)
	{
		string raw = story.state.ToJson();
		JToken token = JToken.Parse(raw);
		SortJsonKeys(token);
		sb.AppendLine("STATE_JSON_BEGIN");
		sb.AppendLine(token.ToString(Formatting.Indented));
		sb.AppendLine("STATE_JSON_END");
		sb.AppendLine();
	}

	// Sort object keys alphabetically; leave arrays in source order (output
	// stream, callstack frames, eval stack are order-significant).
	static void SortJsonKeys(JToken token)
	{
		if (token is JObject obj) {
			var props = obj.Properties().OrderBy(p => p.Name, StringComparer.Ordinal).ToList();
			obj.RemoveAll();
			foreach (var p in props) {
				obj.Add(p);
				SortJsonKeys(p.Value);
			}
		} else if (token is JArray arr) {
			foreach (var item in arr) SortJsonKeys(item);
		}
	}

	// storySeed accessibility shifts across ink-engine versions; reflect.
	static void SeedStoryRng(Story story, int seed)
	{
		var stateType = story.state.GetType();
		var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

		var prop = stateType.GetProperty("storySeed", flags);
		if (prop != null && prop.CanWrite) {
			prop.SetValue(story.state, seed, null);
		} else {
			var field = stateType.GetField("storySeed", flags);
			if (field != null) field.SetValue(story.state, seed);
			else Console.Error.WriteLine("WARN: could not set storySeed; RNG-dependent paths may diverge");
		}

		var prevProp = stateType.GetProperty("previousRandom", flags);
		if (prevProp != null && prevProp.CanWrite) {
			prevProp.SetValue(story.state, 0, null);
		} else {
			var prevField = stateType.GetField("previousRandom", flags);
			if (prevField != null) prevField.SetValue(story.state, 0);
		}
	}

	static string? ReflectString(object obj, string memberName)
	{
		var t = obj.GetType();
		var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
		var prop = t.GetProperty(memberName, flags);
		if (prop != null) return prop.GetValue(obj, null) as string;
		var field = t.GetField(memberName, flags);
		if (field != null) return field.GetValue(obj) as string;
		return null;
	}

	static int ReflectThreadIndex(Choice c)
	{
		var threadObj = ReflectMember(c, "threadAtGeneration");
		if (threadObj == null) return -1;
		var t = threadObj.GetType();
		var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
		var prop = t.GetProperty("threadIndex", flags);
		if (prop != null) return (int)prop.GetValue(threadObj, null)!;
		var field = t.GetField("threadIndex", flags);
		if (field != null) return (int)field.GetValue(threadObj)!;
		return -1;
	}

	static object? ReflectMember(object obj, string memberName)
	{
		var t = obj.GetType();
		var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
		var prop = t.GetProperty(memberName, flags);
		if (prop != null) return prop.GetValue(obj, null);
		var field = t.GetField(memberName, flags);
		if (field != null) return field.GetValue(obj);
		return null;
	}

	static string Quote(string? s)
	{
		if (s == null) return "null";
		var b = new StringBuilder(s.Length + 2);
		b.Append('"');
		for (int i = 0; i < s.Length; i++) {
			char c = s[i];
			switch (c) {
				case '\\': b.Append("\\\\"); break;
				case '"':  b.Append("\\\""); break;
				case '\n': b.Append("\\n");  break;
				case '\r': b.Append("\\r");  break;
				case '\t': b.Append("\\t");  break;
				default:
					if (c < 0x20) b.Append("\\u").Append(((int)c).ToString("X4"));
					else b.Append(c);
					break;
			}
		}
		b.Append('"');
		return b.ToString();
	}
}
