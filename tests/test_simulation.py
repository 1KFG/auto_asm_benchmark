"""Unit tests for the simulation controller scripts.

These tests exercise the pure-Python, deterministic transforms and dispatchers
without requiring any external simulator binaries to be installed.
"""

import gzip
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from simulation import controller  # noqa: E402
from simulation import degrade_quality as dq  # noqa: E402
from simulation import simulate_reads as sr    # noqa: E402
from simulation import spike_contamination as spk  # noqa: E402
from simulation import subset_chromosome as sc  # noqa: E402


class TestDegrade(unittest.TestCase):
    def test_qscore_floor(self):
        # '!' is Q0, '5' is Q20; floor=5 raises '!' to Q5 ('&')
        q = "!5"
        self.assertEqual(dq._q_floor(q, 5), "&5")

    def test_offbias_trim(self):
        self.assertEqual(dq._offbias_trim("ACGTACGT", "IIIIIIII", 4, 4), ("ACGT", "IIII"))

    def test_miscall_is_reproducible_and_alt(self):
        rng1 = __import__("random").Random(7)
        rng2 = __import__("random").Random(7)
        s = "ACGT" * 10
        m1 = dq._miscall(s, "II" * 20, 0.1, rng1)
        m2 = dq._miscall(s, "II" * 20, 0.1, rng2)
        self.assertEqual(m1, m2)
        for a, b in zip(s, m1):
            if a != b:
                self.assertNotEqual(a, b)
                # substitution is one of the other bases (N included in alphabet)

    def test_edge_empty_seq(self):
        self.assertEqual(dq._offbias_trim("", "", 4, 4), ("", ""))

    def test_adapter_dimer_is_adapter_revcomp(self):
        # a read-length dimer is a tiling of adapter + revcomp(adapter)
        d = dq._adapter_dimer(len(dq.ADAPTER_FWD) * 2)
        self.assertEqual(d, dq.ADAPTER_FWD + dq._revcomp(dq.ADAPTER_FWD))
        self.assertEqual(len(d), len(dq.ADAPTER_FWD) * 2)

    def test_adapter_only_returns_pure_adapter(self):
        seq, qual = dq._adapter_only("ACGT" * 10, "II" * 40, None)
        self.assertTrue(set(seq) <= set(dq.ADAPTER_FWD))
        self.assertEqual(len(seq), 40)
        self.assertTrue(set(qual) == {"I"})

    def test_adapter_carryover_appends_3p_adapter(self):
        seq, qual = dq._adapter_carryover("ACGT" * 10, "I" * 40, 25)
        self.assertEqual(len(seq), 65)
        self.assertEqual(seq[-25:], dq.ADAPTER_FWD[:25])
        self.assertEqual(len(qual), 65)

    def test_adapter_carryover_zero_bases_is_noop(self):
        seq, qual = dq._adapter_carryover("ACGT", "IIII", 0)
        self.assertEqual((seq, qual), ("ACGT", "IIII"))

    def test_degrade_adapter_only_fraction(self):
        # entire reads become adapter dimers at fraction 1.0; count preserved
        rng = __import__("random").Random(1)
        mechs = [{"mechanism": "adapter_only", "params": {"fraction": 1.0}}]
        with tempfile.TemporaryDirectory() as d:
            inp = Path(d) / "in.fq"
            outp = Path(d) / "out.fq"
            inp.write_text("@r0/1\nACGTACGT\n+\nIIIIIIII\n@r1/1\nACGTACGT\n+\nIIIIIIII\n")
            n_in, n_out = dq.degrade_fastq(inp, outp, mechs, 1)
            self.assertEqual((n_in, n_out), (2, 2))
            lines = outp.read_text().splitlines()
            for el in range(2):
                self.assertEqual(len(lines[el * 4 + 1]), 8)

    def test_degrade_carryover_tails(self):
        mechs = [{"mechanism": "adapter_carryover", "params": {"fraction": 1.0, "bases_from_3": 10}}]
        with tempfile.TemporaryDirectory() as d:
            inp = Path(d) / "in.fq"
            outp = Path(d) / "out.fq"
            inp.write_text("@r0/1\nACGTACGT\n+\nIIIIIIII\n")
            dq.degrade_fastq(inp, outp, mechs, 1)
            header, seq, plus, qual = outp.read_text().splitlines()
            self.assertEqual(seq[-10:], dq.ADAPTER_FWD[:10])
            self.assertEqual(len(seq), 18)


class TestSimulateReads(unittest.TestCase):
    def test_genome_length(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "ref.fa"
            f.write_text(">c1\nACGTACGT\n>c2\nACGT\n")
            self.assertEqual(sr.genome_length(f), 12)

    def test_pick_backend_known(self):
        # candidate ordering (unchecked; does not require binaries on PATH)
        self.assertEqual(sr.candidate_backends("illumina", "wgsim")[0], "wgsim")
        self.assertEqual(sr.candidate_backends("illumina")[0], "wgsim")
        self.assertEqual(sr.candidate_backends("hifi", "pbsim3")[0], "pbsim3")
        self.assertEqual(sr.candidate_backends("nanopore", "badread")[0], "badread")
        # pick_backend returns None gracefully when nothing is installed
        self.assertIn(sr.pick_backend("nanopore", "__no_such_sim__"), (None, "badread"))


class TestSubset(unittest.TestCase):
    def test_subset_by_name(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "ref.fa"
            f.write_text(">chr1\nACGTACGT\n>chr2\nTTTT\n")
            out = Path(d) / "chr1.fa"
            sc.subset_fasta(f, out, "chr1")
            names = [n for n, _ in sr.fasta_records(out)]
            self.assertEqual(names, ["chr1"])
            self.assertEqual(len(list(sr.fasta_records(out))), 1)

    def test_list_chromosomes(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "ref.fa"
            f.write_text(">a\nAAAA\n>b\nCCCC\n>c\nGGGG\n")
            self.assertEqual(sc.list_chromosomes(f), ["a", "b", "c"])


class TestSpikeContamination(unittest.TestCase):
    """Regression: contaminant records must be well-formed 4-line FASTQ.

    spike_fastq()/sample_contaminant_reads() previously merged '+' into the
    quality line (3-line records), corrupting every contaminated dataset.
    """

    HOST = "@h0\nACGTACGT\n+\nIIIIIIII\n@h1\nACGTACGT\n+\nIIIIIIII\n"
    CONT = "@c0\nTTTTTTTT\n+\nJJJJJJJJ\n@c1\nTTTTTTTT\n+\nJJJJJJJJ\n"

    @staticmethod
    def _assert_well_formed(path, expected_records):
        lines = Path(path).read_text().splitlines()
        self = None
        assert len(lines) % 4 == 0, f"{len(lines)} lines is not a multiple of 4"
        assert len(lines) // 4 == expected_records, f"got {len(lines)//4} records, wanted {expected_records}"
        seqs = lines[1::4]
        quals = lines[3::4]
        assert len(quals) == len(seqs)
        for plus, seq, qual in zip(lines[2::4], seqs, quals):
            assert len(qual) == len(seq), "quality length != sequence length"
            assert plus.startswith("+"), f"bad plus line {plus!r}"
            assert len(plus) < len(seq) + 1, f"quality merged onto plus line: {plus!r}"

    def test_spike_fastq_output_is_four_line(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            host, cont, out = d / "host.fq", d / "cont.fq", d / "out.fq"
            host.write_text(self.HOST)
            cont.write_text(self.CONT)
            n_take, cont_n = spk.spike_fastq(str(host), str(cont), str(out), 1.0, 1)
            self.assertEqual((n_take, cont_n), (2, 2))
            self._assert_well_formed(out, 4)

    def test_sample_contaminant_reads_output_is_four_line(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            host, cont, out = d / "host.fq", d / "cont.fq", d / "out.fq"
            host.write_text(self.HOST)
            cont.write_text(self.CONT)
            n_take, cont_n = spk.sample_contaminant_reads(str(cont), str(out),
                                                          8 * len(self.HOST.splitlines()) // 4, 1.0, 1)
            self.assertEqual((n_take, cont_n), (2, 2))
            self._assert_well_formed(out, 2)

    def test_spike_fastq_separate_output_is_four_line(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            host, cont, out = d / "host.fq", d / "cont.fq", d / "out.fq"
            host.write_text(self.HOST)
            cont.write_text(self.CONT)
            spk.spike_fastq(str(host), str(cont), str(out), 1.0, 1, separate=True)
            self._assert_well_formed(str(out).replace(".fastq", ".host.fastq"), 2)
            self._assert_well_formed(str(out).replace(".fastq", ".contam.fastq"), 2)


class TestFastaRecords(unittest.TestCase):
    def test_wrapped_sequences(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "w.fa"
            f.write_text(">h\nACGT\nACGT\n")
            name, seq = next(sr.fasta_records(f))
            self.assertEqual(name, "h")
            self.assertEqual(seq, "ACGTACGT")


class TestVcat(unittest.TestCase):
    """Regression: host and each contamination spike are simulated by
    independent pbsim3/ART invocations that each number reads from scratch
    (e.g. every source's first read is "S1_1"), so naively concatenating
    them collides on identical IDs. flye hard-errors on duplicate read IDs
    (found running cryneo_sim_contam_hi_001 through flye_pipeline); vcat
    must tag each source's reads to keep them globally unique.
    """

    def test_prefixes_ids_per_source_and_preserves_records(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            host, cont, out = d / "host.fq", d / "cont.fq", d / "out.fq"
            # both sources independently "restart" their own S1_1 naming
            host.write_text("@S1_1 extra\nACGT\n+\nIIII\n@S1_2\nACGT\n+\nIIII\n")
            cont.write_text("@S1_1\nTTTT\n+\nJJJJ\n")
            controller.vcat(out, ("host", host), ("cont0_symbiont", cont))
            lines = out.read_text().splitlines()
            self.assertEqual(len(lines), 12)
            self.assertEqual(lines[0], "@host_S1_1 extra")
            self.assertEqual(lines[4], "@host_S1_2")
            self.assertEqual(lines[8], "@cont0_symbiont_S1_1")
            # sequence/plus/qual lines pass through untouched
            self.assertEqual(lines[1:4], ["ACGT", "+", "IIII"])
            self.assertEqual(lines[9:12], ["TTTT", "+", "JJJJ"])

    def test_output_has_no_duplicate_ids_across_sources(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            host, cont, out = d / "host.fq", d / "cont.fq", d / "out.fq"
            host.write_text("@S1_1\nACGT\n+\nIIII\n")
            cont.write_text("@S1_1\nTTTT\n+\nJJJJ\n")
            controller.vcat(out, ("host", host), ("cont0", cont))
            ids = out.read_text().splitlines()[0::4]
            self.assertEqual(len(ids), len(set(ids)))


if __name__ == "__main__":
    unittest.main()
