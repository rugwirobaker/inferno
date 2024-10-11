// Package flag implements flag-related functionality.
package flag

import (
	"context"
	"reflect"
	"time"

	"github.com/spf13/cobra"
)

// Flag wraps the set of flags.
type Flag interface {
	addTo(*cobra.Command)
}

type Set []Flag

func (s Set) addTo(cmd *cobra.Command) {
	for _, flag := range s {
		flag.addTo(cmd)
	}
}

// Add adds flag to cmd, binding them on v should v not be nil.
func Add(cmd *cobra.Command, flags ...Flag) {
	for _, flag := range flags {
		flag.addTo(cmd)
	}
}

// Bool wraps the set of boolean flags.
type Bool struct {
	Name        string
	Shorthand   string
	Description string
	Default     bool
	Hidden      bool
	Aliases     []string
}

func (b Bool) addTo(cmd *cobra.Command) {
	flags := cmd.Flags()

	if b.Shorthand != "" {
		_ = flags.BoolP(b.Name, b.Shorthand, b.Default, b.Description)
	} else {
		_ = flags.Bool(b.Name, b.Default, b.Description)
	}

	f := flags.Lookup(b.Name)
	f.Hidden = b.Hidden

	// Aliases
	for _, name := range b.Aliases {
		makeAlias(b, name).addTo(cmd)
	}
	err := cmd.Flags().SetAnnotation(f.Name, "flyctl_alias", b.Aliases)
	if err != nil {
		panic(err)
	}
}

// String wraps the set of string flags.
type String struct {
	Name              string
	Shorthand         string
	Description       string
	Default           string
	NoOptDefVal       string
	ConfName          string
	EnvName           string
	Hidden            bool
	Aliases           []string
	UseAliasShortHand bool
	CompletionFn      func(ctx context.Context, cmd *cobra.Command, args []string, partial string) ([]string, error)
}

func (s String) addTo(cmd *cobra.Command) {
	flags := cmd.Flags()

	if s.Shorthand != "" {
		_ = flags.StringP(s.Name, s.Shorthand, s.Default, s.Description)
	} else {
		_ = flags.String(s.Name, s.Default, s.Description)
	}

	f := flags.Lookup(s.Name)
	f.Hidden = s.Hidden
	if s.NoOptDefVal != "" {
		f.NoOptDefVal = s.NoOptDefVal
	}

	// Aliases
	for _, name := range s.Aliases {
		makeAlias(s, name).addTo(cmd)
	}
	err := cmd.Flags().SetAnnotation(f.Name, "flyctl_alias", s.Aliases)
	if err != nil {
		panic(err)
	}

	// Completion
	if s.CompletionFn != nil {
		_ = cmd.RegisterFlagCompletionFunc(s.Name, Adapt(s.CompletionFn))
	}
}

// Int wraps the set of int flags.
type Int struct {
	Name        string
	Shorthand   string
	Description string
	Default     int
	Hidden      bool
	Aliases     []string
}

func (i Int) addTo(cmd *cobra.Command) {
	flags := cmd.Flags()

	if i.Shorthand != "" {
		_ = flags.IntP(i.Name, i.Shorthand, i.Default, i.Description)
	} else {
		_ = flags.Int(i.Name, i.Default, i.Description)
	}

	f := flags.Lookup(i.Name)
	f.Hidden = i.Hidden

	// Aliases
	for _, name := range i.Aliases {
		makeAlias(i, name).addTo(cmd)
	}
	err := cmd.Flags().SetAnnotation(f.Name, "flyctl_alias", i.Aliases)
	if err != nil {
		panic(err)
	}
}

// Int wraps the set of int flags.
type Float64 struct {
	Name        string
	Shorthand   string
	Description string
	Default     float64
	Hidden      bool
	Aliases     []string
}

func (i Float64) addTo(cmd *cobra.Command) {
	flags := cmd.Flags()

	if i.Shorthand != "" {
		_ = flags.Float64P(i.Name, i.Shorthand, i.Default, i.Description)
	} else {
		_ = flags.Float64(i.Name, i.Default, i.Description)
	}

	f := flags.Lookup(i.Name)
	f.Hidden = i.Hidden

	// Aliases
	for _, name := range i.Aliases {
		makeAlias(i, name).addTo(cmd)
	}
	err := cmd.Flags().SetAnnotation(f.Name, "flyctl_alias", i.Aliases)
	if err != nil {
		panic(err)
	}
}

// StringSlice wraps the set of string slice flags.
type StringSlice struct {
	Name        string
	Shorthand   string
	Description string
	Default     []string
	ConfName    string
	EnvName     string
	Hidden      bool
	Aliases     []string
}

func (ss StringSlice) addTo(cmd *cobra.Command) {
	flags := cmd.Flags()

	if ss.Shorthand != "" {
		_ = flags.StringSliceP(ss.Name, ss.Shorthand, ss.Default, ss.Description)
	} else {
		_ = flags.StringSlice(ss.Name, ss.Default, ss.Description)
	}

	f := flags.Lookup(ss.Name)
	f.Hidden = ss.Hidden

	// Aliases
	for _, name := range ss.Aliases {
		makeAlias(ss, name).addTo(cmd)
	}
	err := cmd.Flags().SetAnnotation(f.Name, "flyctl_alias", ss.Aliases)
	if err != nil {
		panic(err)
	}
}

// StringArray wraps the set of string array flags.
type StringArray struct {
	Name        string
	Shorthand   string
	Description string
	Default     []string
	ConfName    string
	EnvName     string
	Hidden      bool
	Aliases     []string
}

func (ss StringArray) addTo(cmd *cobra.Command) {
	flags := cmd.Flags()

	if ss.Shorthand != "" {
		_ = flags.StringArrayP(ss.Name, ss.Shorthand, ss.Default, ss.Description)
	} else {
		_ = flags.StringArray(ss.Name, ss.Default, ss.Description)
	}

	f := flags.Lookup(ss.Name)
	f.Hidden = ss.Hidden

	// Aliases
	for _, name := range ss.Aliases {
		makeAlias(ss, name).addTo(cmd)
	}
	err := cmd.Flags().SetAnnotation(f.Name, "flyctl_alias", ss.Aliases)
	if err != nil {
		panic(err)
	}
}

// Duration wraps the set of duration flags.
type Duration struct {
	Name        string
	Shorthand   string
	Description string
	Default     time.Duration
	ConfName    string
	EnvName     string
	Hidden      bool
	Aliases     []string
}

func (d Duration) addTo(cmd *cobra.Command) {
	flags := cmd.Flags()

	if d.Shorthand != "" {
		_ = flags.DurationP(d.Name, d.Shorthand, d.Default, d.Description)
	} else {
		_ = flags.Duration(d.Name, d.Default, d.Description)
	}

	f := flags.Lookup(d.Name)
	f.Hidden = d.Hidden

	// Aliases
	for _, name := range d.Aliases {
		makeAlias(d, name).addTo(cmd)
	}
	err := cmd.Flags().SetAnnotation(f.Name, "flyctl_alias", d.Aliases)
	if err != nil {
		panic(err)
	}
}

// Yes returns a yes bool flag.
func Yes() Bool {
	return Bool{
		Name:        "yes",
		Shorthand:   "y",
		Description: "Accept all confirmations",
		Aliases:     []string{"auto-confirm"},
	}
}

// Image returns a Docker image config string flag.
func Image() String {
	return String{
		Name:        "image",
		Shorthand:   "i",
		Description: "The Docker image to run",
	}
}

func makeAlias[T any](template T, name string) T {

	var ret T
	value := reflect.ValueOf(&ret).Elem()

	descField := reflect.ValueOf(template).FieldByName("Description")
	if descField.IsValid() {
		value.FieldByName("Description").SetString(descField.String())
	}

	nameField := value.FieldByName("Name")
	if nameField.IsValid() {
		nameField.SetString(name)
	}

	hiddenField := value.FieldByName("Hidden")
	if hiddenField.IsValid() {
		hiddenField.SetBool(true)
	}

	useAliasShortHandField := reflect.ValueOf(template).FieldByName("UseAliasShortHand")
	if useAliasShortHandField.IsValid() {
		useAliasShortHand := useAliasShortHandField.Interface().(bool)
		if useAliasShortHand == true {
			value.FieldByName("Shorthand").SetString(string(name[0]))
		}
	}

	return ret
}
