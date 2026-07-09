import { useTheme } from "next-themes";
import { cn } from "@/lib/utils";

interface Props {
	className?: string;
	logoUrl?: string;
	logoLightUrl?: string;
}

export const Logo = ({
	className = "size-14",
	logoUrl,
	logoLightUrl,
}: Props) => {
	const { resolvedTheme } = useTheme();
	const effectiveUrl =
		resolvedTheme === "light" && logoLightUrl ? logoLightUrl : logoUrl;

	if (effectiveUrl) {
		return (
			<img
				src={effectiveUrl}
				alt="Organization Logo"
				className={cn(className, "object-contain rounded-sm")}
			/>
		);
	}

	// ponytail: use local logo.svg for Nettalco branding
	return (
		// biome-ignore lint/performance/noImgElement: static local logo
		<img
			src="/logo.svg"
			alt="Nettalco"
			className={cn(className, "object-contain rounded-sm")}
		/>
	);
};
