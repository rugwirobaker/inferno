package render

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
	"text/tabwriter"

	"github.com/AlecAivazis/survey/v2"
	"github.com/AlecAivazis/survey/v2/terminal"
	"github.com/google/go-cmp/cmp"
	"github.com/rugwirobaker/inferno/internal/iostreams"
)

func JSON(w io.Writer, v interface{}) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func WriteTable(w io.Writer, title string, rows [][]string, cols ...string) {
	if strings.TrimSpace(title) != "" {
		fmt.Fprintf(w, "\033[1m%s\033[0m\n", title)
	}

	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	defer tw.Flush()

	for _, column := range cols {
		fmt.Fprintf(tw, "%s\t", strings.ToUpper(column))
	}

	fmt.Fprintln(tw)

	for _, row := range rows {
		for _, value := range row {
			fmt.Fprintf(tw, "%s\t", value)
		}
		fmt.Fprintln(tw)
	}
	fmt.Fprintln(tw)
}

func WriteVerticalTable(w io.Writer, title string, objects [][]string, cols ...string) {
	if strings.TrimSpace(title) != "" {
		fmt.Fprintf(w, "\033[1m%s\033[0m\n", title)
	}

	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	defer tw.Flush()

	for _, object := range objects {
		for i, col := range cols {
			fmt.Fprintf(tw, " %s\t=\t%s\n", col, object[i])
		}
	}
	fmt.Fprintln(tw)
}

func Confirmf(ctx context.Context, format string, a ...interface{}) (bool, error) {
	return Confirm(ctx, fmt.Sprintf(format, a...))
}

func Confirm(ctx context.Context, message string) (confirm bool, err error) {
	var opt survey.AskOpt
	prompt := &survey.Confirm{
		Message: message,
	}

	if opt, err = newSurveyIO(ctx); err != nil {
		return
	}
	err = survey.AskOne(prompt, &confirm, opt)

	return
}

var errNonInteractive = fmt.Errorf("non-interactive terminal")

func newSurveyIO(ctx context.Context) (survey.AskOpt, error) {
	io := iostreams.FromContext(ctx)

	in, ok := io.In.(terminal.FileReader)
	if !ok {
		return nil, errNonInteractive
	}

	out, ok := io.Out.(terminal.FileWriter)
	if !ok {
		return nil, errNonInteractive
	}
	return survey.WithStdio(in, out, io.ErrOut), nil
}

func PrettyDiff(original, new string) string {
	diff := cmp.Diff(original, new)
	diffSlice := strings.Split(diff, "\n")
	var str string
	additionReg := regexp.MustCompile(`^\+.*`)
	deletionReg := regexp.MustCompile(`^\-.*`)
	for _, val := range diffSlice {
		vB := []byte(val)

		if additionReg.Match(vB) {
			// str += colorize.Green(val) + "\n"
			str += "\x1b[32m" + val + "\x1b[0m" + "\n"
		} else if deletionReg.Match(vB) {
			//str += colorize.Red(val) + "\n"
			str += "\x1b[31m" + val + "\x1b[0m" + "\n"
		} else {
			str += val + "\n"
		}
	}
	delim := "\"\"\""
	rx := regexp.MustCompile(`(?s)` + regexp.QuoteMeta(delim) + `(.*?)` + regexp.QuoteMeta(delim))
	match := rx.FindStringSubmatch(str)
	if len(match) > 0 {
		return strings.Trim(match[1], "\n")
	}
	return ""
}
