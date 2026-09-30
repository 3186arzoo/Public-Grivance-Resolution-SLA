# Public Grievance Resolution SLA: Capstone Topic 17

**Author:** Arzoo Kumari Ojha
**GitHub:** [3186arzoo](https://github.com/3186arzoo)

A city runs a public grievance portal. The commissioner wants to know how long complaints take to close, which wards and categories miss the 7-day SLA, and whether the backlog is growing. This project takes about 60,000 generated complaints from raw files through a Databricks Bronze → Silver → Gold pipeline and into Snowflake, where the questions are answered in SQL.

**Hosted report:** https://3186arzoo.github.io/Capstone_Topic17_Grievance_SLA/
**Google Drive folder:** _add link here_

## Pipeline

```
Raw CSV/JSON  →  Bronze  →  Silver  →  Gold  →  CSV export  →  Snowflake stage  →  COPY INTO  →  SQL answers
                (Databricks)                                     (Snowflake)
```

| Layer | What it holds |
|---|---|
| Bronze | Every row exactly as it arrived, with source file and ingest time. No cleaning. |
| Silver | Deduplicated, validated complaints. All data decisions are made here. |
| Gold | One row per week × ward × category (8,320 rows), with raised, closed, open at week end, median and p90 resolution hours, breaches and breach rate. |

## Silver decisions and row counts

| Step | Rows |
|---|---|
| Bronze | 62,300 |
| After removing duplicate complaint IDs | 60,500 |
| Rejected: ward `W99` not in ward master (`unknown_ward`) | −500 |
| Rejected: raised date outside 1 Jan–31 May 2025 | −700 |
| Rejected: closed before it was raised | −900 |
| **Silver** | **58,400** |

Open complaints and closed complaints with a lost timestamp are kept apart. An open complaint has no closure time yet. A closed complaint with a lost timestamp (`closure_known = false`, 1,200 rows) was closed at an unknown time. Merging the two would overstate the backlog.

## Snowflake load

Both Silver (58,400 rows) and Gold (8,320 rows) were exported as one CSV each, uploaded to an internal stage and loaded with `COPY INTO`. Running the load a second time reported *"Copy executed with 0 files processed"* for both tables, so nothing was loaded twice.

## Verification results

| Check | Expected | Result |
|---|---|---|
| Second `COPY INTO` (Silver and Gold) | 0 files processed | Passed |
| Silver rows | 58,400 | 58,400 |
| Gold rows | 8,320 | 8,320 |
| `status = 'CLOSED'` with `closure_known = false` | 1,200 | 1,200 |
| Rows in the worked backlog query | 8,320 | 8,320 |
| Worked-query backlog at window close vs Silver rows minus `closure_known` rows | equal | 10,075 = 10,075 |
| Category medians in the planted order | low to high | Passed |

`status = 'OPEN'` with `closure_known = false` returns 8,875. That is expected, since open complaints have no closure time. No open complaint has a closure timestamp.

## Answers

**1. Median resolution time.** By category, from fastest to slowest: Stray Animals 12.1 h, Streetlight 18.0 h, Garbage 30.3 h, Water Supply 48.6 h, Property Tax 72.9 h, Drainage 95.7 h, Road Repair 240 h, Encroachment 357.1 h. Ward-level medians are close together: the ten slowest wards sit between about 58 and 61 hours (W05 highest at 60.6 h), so category matters far more than ward.

**2. SLA breaches (168 hours).** A complaint breaches when it closes after 168 hours, or when it is still open 168 hours before the window closes. The top of the breach ranking is dominated by wards W11, W17, W23, W31 and W37 at a 100% breach rate in several categories. This comes from how the data was generated, where every complaint in those wards is still open. It would deserve investigation in a real dataset.

**3. Is the backlog growing?** Yes. Backlog is arrivals minus departures added up week by week from the two timestamps. It starts at 1,180 in the week of 30 Dec 2024, climbs steadily (2,073, 2,721, 3,130, 3,554, 4,060, 4,473, 4,830 over the following weeks) and peaks at 10,262.

## Backlog at window close: two figures

| Source | Backlog | Treatment of the 1,200 lost-timestamp rows |
|---|---|---|
| Snowflake worked query (timestamps only) | 10,075 | Counted as still open |
| Databricks Gold table | 8,875 | Treated as closed |

The difference is exactly the 1,200 complaints that are `CLOSED` with `closure_known = false` (8,875 + 1,200 = 10,075).

## Repository structure

```
Capstone_Topic17_Grievance_SLA/
├── README.md
├── index.html                      hosted report page
├── notebooks/                      Databricks notebooks (.ipynb)
├── snowflake/
│   ├── snowflake_topic17_grievance_sla.sql   clean script, run in order
│   └── capstone_worksheet_history.sql        raw worksheet incl. earlier failed attempts
├── exports/
│   ├── silver_complaint.csv
│   └── gold_grievance_weekly.csv
└── screenshots/
    ├── snowflake/
    └── databricks/
```

## How to reproduce

1. Run the notebooks in `notebooks/` in order to build Bronze, Silver and Gold.
2. Export Silver and Gold as single CSV files (see `exports/`).
3. In Snowflake, upload both files to `GRIEVANCE_STAGE` and run `snowflake/snowflake_topic17_grievance_sla.sql` statement by statement.
